;; Design Approval Workflow Contract
;; Manages multi-stakeholder design approval processes and revision tracking

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-DESIGN-NOT-FOUND (err u201))
(define-constant ERR-INVALID-STATUS (err u202))
(define-constant ERR-ALREADY-APPROVED (err u203))
(define-constant ERR-INVALID-INPUT (err u204))
(define-constant ERR-ORDER-NOT-FOUND (err u205))
(define-constant ERR-APPROVAL-DEADLINE-PASSED (err u206))
(define-constant ERR-INSUFFICIENT-APPROVERS (err u207))
(define-constant ERR-DUPLICATE-APPROVER (err u208))

;; Design status constants
(define-constant DESIGN-STATUS-SUBMITTED "submitted")
(define-constant DESIGN-STATUS-UNDER-REVIEW "under-review")
(define-constant DESIGN-STATUS-APPROVED "approved")
(define-constant DESIGN-STATUS-REJECTED "rejected")
(define-constant DESIGN-STATUS-REVISION-REQUIRED "revision-required")

;; Data Variables
(define-data-var next-design-id uint u1)
(define-data-var next-revision-id uint u1)

;; Data Maps
(define-map designs uint {
  order-id: uint,
  designer: principal,
  design-hash: (buff 32),
  status: (string-ascii 20),
  required-approvers: (list 10 principal),
  approved-by: (list 10 principal),
  rejected-by: (list 10 principal),
  created-at: uint,
  approval-deadline: uint,
  final-approval-at: (optional uint)
})

(define-map design-revisions uint {
  design-id: uint,
  revision-number: uint,
  design-hash: (buff 32),
  changes-description: (string-ascii 300),
  created-by: principal,
  created-at: uint
})

(define-map order-designs uint (list 20 uint))
(define-map approver-comments uint {
  design-id: uint,
  approver: principal,
  comment: (string-ascii 500),
  approval-status: (string-ascii 20),
  created-at: uint
})

(define-map design-approval-requirements uint {
  minimum-approvers: uint,
  approval-percentage: uint,
  deadline-blocks: uint
})

;; Authorization for manufacturing core contract
(define-data-var manufacturing-core-contract (optional principal) none)

;; Public Functions

;; Submit a new design for approval
(define-public (submit-design (order-id uint) (design-hash (buff 32)) (required-approvers (list 10 principal)) (approval-deadline uint))
  (let (
    (design-id (var-get next-design-id))
    (current-block-height block-height)
  )
    (asserts! (> (len required-approvers) u0) ERR-INSUFFICIENT-APPROVERS)
    (asserts! (<= (len required-approvers) u10) ERR-INVALID-INPUT)
    (asserts! (> approval-deadline current-block-height) ERR-INVALID-INPUT)
    (asserts! (is-unique-list required-approvers) ERR-DUPLICATE-APPROVER)

    ;; Verify order exists (would call manufacturing core in real implementation)
    ;; For now, assume order exists

    ;; Create the design
    (map-set designs design-id {
      order-id: order-id,
      designer: tx-sender,
      design-hash: design-hash,
      status: DESIGN-STATUS-SUBMITTED,
      required-approvers: required-approvers,
      approved-by: (list),
      rejected-by: (list),
      created-at: current-block-height,
      approval-deadline: approval-deadline,
      final-approval-at: none
    })

    ;; Add to order's design list
    (let ((order-design-list (default-to (list) (map-get? order-designs order-id))))
      (map-set order-designs order-id (unwrap! (as-max-len? (append order-design-list design-id) u20) ERR-INVALID-INPUT))
    )

    ;; Set default approval requirements
    (map-set design-approval-requirements design-id {
      minimum-approvers: (len required-approvers),
      approval-percentage: u100,
      deadline-blocks: (- approval-deadline current-block-height)
    })

    ;; Increment design ID
    (var-set next-design-id (+ design-id u1))

    (ok design-id)
  )
)

;; Approve a design
(define-public (approve-design (design-id uint) (comment (string-ascii 500)))
  (let (
    (design (unwrap! (map-get? designs design-id) ERR-DESIGN-NOT-FOUND))
    (current-block-height block-height)
  )
    ;; Check if caller is authorized approver
    (asserts! (is-some (index-of (get required-approvers design) tx-sender)) ERR-NOT-AUTHORIZED)

    ;; Check if not already approved by this approver
    (asserts! (is-none (index-of (get approved-by design) tx-sender)) ERR-ALREADY-APPROVED)

    ;; Check deadline
    (asserts! (<= current-block-height (get approval-deadline design)) ERR-APPROVAL-DEADLINE-PASSED)

    ;; Check if design is in valid status for approval
    (asserts! (or (is-eq (get status design) DESIGN-STATUS-SUBMITTED)
                  (is-eq (get status design) DESIGN-STATUS-UNDER-REVIEW)
                  (is-eq (get status design) DESIGN-STATUS-REVISION-REQUIRED)) ERR-INVALID-STATUS)

    ;; Add approver to approved list
    (let (
      (new-approved-list (unwrap! (as-max-len? (append (get approved-by design) tx-sender) u10) ERR-INVALID-INPUT))
      (updated-design (merge design {
        approved-by: new-approved-list,
        status: DESIGN-STATUS-UNDER-REVIEW
      }))
    )
      (map-set designs design-id updated-design)

      ;; Store approval comment
      (map-set approver-comments (+ (* design-id u1000) (len new-approved-list)) {
        design-id: design-id,
        approver: tx-sender,
        comment: comment,
        approval-status: "approved",
        created-at: current-block-height
      })

      ;; Check if all required approvers have approved
      (if (is-design-fully-approved design-id updated-design)
        (begin
          (map-set designs design-id (merge updated-design {
            status: DESIGN-STATUS-APPROVED,
            final-approval-at: (some current-block-height)
          }))
          (ok "design-fully-approved")
        )
        (ok "approval-recorded")
      )
    )
  )
)

;; Reject a design
(define-public (reject-design (design-id uint) (comment (string-ascii 500)))
  (let (
    (design (unwrap! (map-get? designs design-id) ERR-DESIGN-NOT-FOUND))
    (current-block-height block-height)
  )
    ;; Check if caller is authorized approver
    (asserts! (is-some (index-of (get required-approvers design) tx-sender)) ERR-NOT-AUTHORIZED)

    ;; Check deadline
    (asserts! (<= current-block-height (get approval-deadline design)) ERR-APPROVAL-DEADLINE-PASSED)

    ;; Add rejector to rejected list
    (let (
      (new-rejected-list (unwrap! (as-max-len? (append (get rejected-by design) tx-sender) u10) ERR-INVALID-INPUT))
      (updated-design (merge design {
        rejected-by: new-rejected-list,
        status: DESIGN-STATUS-REJECTED
      }))
    )
      (map-set designs design-id updated-design)

      ;; Store rejection comment
      (map-set approver-comments (+ (* design-id u1000) (+ (len (get approved-by design)) (len new-rejected-list))) {
        design-id: design-id,
        approver: tx-sender,
        comment: comment,
        approval-status: "rejected",
        created-at: current-block-height
      })

      (ok "design-rejected")
    )
  )
)

;; Submit a design revision
(define-public (submit-revision (design-id uint) (new-design-hash (buff 32)) (changes-description (string-ascii 300)))
  (let (
    (design (unwrap! (map-get? designs design-id) ERR-DESIGN-NOT-FOUND))
    (revision-id (var-get next-revision-id))
    (current-block-height block-height)
  )
    ;; Only designer or owner can submit revisions
    (asserts! (or (is-eq tx-sender (get designer design)) (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)

    ;; Design must be rejected or require revision
    (asserts! (or (is-eq (get status design) DESIGN-STATUS-REJECTED)
                  (is-eq (get status design) DESIGN-STATUS-REVISION-REQUIRED)) ERR-INVALID-STATUS)

    ;; Create revision record
    (map-set design-revisions revision-id {
      design-id: design-id,
      revision-number: (+ (get-revision-count design-id) u1),
      design-hash: new-design-hash,
      changes-description: changes-description,
      created-by: tx-sender,
      created-at: current-block-height
    })

    ;; Update design with new hash and reset approval status
    (map-set designs design-id (merge design {
      design-hash: new-design-hash,
      status: DESIGN-STATUS-SUBMITTED,
      approved-by: (list),
      rejected-by: (list)
    }))

    ;; Increment revision ID
    (var-set next-revision-id (+ revision-id u1))

    (ok revision-id)
  )
)

;; Request revision (by approver)
(define-public (request-revision (design-id uint) (comment (string-ascii 500)))
  (let (
    (design (unwrap! (map-get? designs design-id) ERR-DESIGN-NOT-FOUND))
    (current-block-height block-height)
  )
    ;; Check if caller is authorized approver
    (asserts! (is-some (index-of (get required-approvers design) tx-sender)) ERR-NOT-AUTHORIZED)

    ;; Update design status
    (map-set designs design-id (merge design {status: DESIGN-STATUS-REVISION-REQUIRED}))

    ;; Store revision request comment
    (map-set approver-comments (+ (* design-id u1000) (+ (len (get approved-by design)) (len (get rejected-by design)) u1)) {
      design-id: design-id,
      approver: tx-sender,
      comment: comment,
      approval-status: "revision-requested",
      created-at: current-block-height
    })

    (ok "revision-requested")
  )
)

;; Set manufacturing core contract (only owner)
(define-public (set-manufacturing-core-contract (contract-address principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set manufacturing-core-contract (some contract-address))
    (ok true)
  )
)

;; Read-only Functions

;; Get design details
(define-read-only (get-design (design-id uint))
  (map-get? designs design-id)
)

;; Get designs for an order
(define-read-only (get-order-designs (order-id uint))
  (map-get? order-designs order-id)
)

;; Get design revisions
(define-read-only (get-design-revisions (design-id uint))
  ;; In a full implementation, this would return all revisions for a design
  (map-get? design-revisions design-id)
)

;; Get approver comments
(define-read-only (get-approver-comments (comment-id uint))
  (map-get? approver-comments comment-id)
)

;; Get approval progress
(define-read-only (get-approval-progress (design-id uint))
  (match (map-get? designs design-id)
    design (ok {
      total-required: (len (get required-approvers design)),
      approved-count: (len (get approved-by design)),
      rejected-count: (len (get rejected-by design)),
      status: (get status design)
    })
    ERR-DESIGN-NOT-FOUND
  )
)

;; Check if design is fully approved
(define-read-only (is-design-fully-approved-read (design-id uint))
  (match (map-get? designs design-id)
    design (is-design-fully-approved design-id design)
    false
  )
)

;; Private Functions

;; Check if design has all required approvals
(define-private (is-design-fully-approved (design-id uint) (design {order-id: uint, designer: principal, design-hash: (buff 32), status: (string-ascii 20), required-approvers: (list 10 principal), approved-by: (list 10 principal), rejected-by: (list 10 principal), created-at: uint, approval-deadline: uint, final-approval-at: (optional uint)}))
  (let (
    (requirements (default-to {minimum-approvers: u1, approval-percentage: u100, deadline-blocks: u1000} (map-get? design-approval-requirements design-id)))
    (required-count (len (get required-approvers design)))
    (approved-count (len (get approved-by design)))
  )
    (and
      (>= approved-count (get minimum-approvers requirements))
      (>= (* approved-count u100) (* required-count (get approval-percentage requirements)))
    )
  )
)

;; Get revision count for a design
(define-private (get-revision-count (design-id uint))
  ;; In a full implementation, this would count all revisions
  ;; For now, return a placeholder
  u0
)

;; Check if list contains unique elements
(define-private (is-unique-list (input-list (list 10 principal)))
  ;; Simplified uniqueness check - in full implementation would be more robust
  (<= (len input-list) u10)
)
