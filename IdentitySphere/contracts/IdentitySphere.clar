;; Decentralized Identity Verification Contract
;; Allows users to create, manage, and verify digital identities
;; with attribute attestations and verification processes

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-status (err u104))
(define-constant err-expired (err u105))

;; Data Maps
(define-map identities
    principal
    {
        did: (string-ascii 50),
        status: (string-ascii 20),
        created-at: uint,
        updated-at: uint,
        verification-level: uint,
        recovery-address: (optional principal)
    }
)

(define-map attributes
    {
        owner: principal,
        key: (string-ascii 50)
    }
    {
        value: (string-ascii 100),
        verified: bool,
        verifier: (optional principal),
        timestamp: uint,
        expiration: uint
    }
)

(define-map verifiers
    principal
    {
        name: (string-ascii 50),
        verification-count: uint,
        active: bool,
        trust-score: uint,
        join-date: uint
    }
)

(define-map verification-requests
    uint
    {
        requester: principal,
        attribute-key: (string-ascii 50),
        status: (string-ascii 20),
        verifier: (optional principal),
        created-at: uint,
        completed-at: (optional uint)
    }
)

;; Data Variables
(define-data-var request-counter uint u0)
(define-data-var min-trust-score uint u75)
(define-data-var verification-fee uint u100)

;; Private Functions
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner)
)

(define-private (is-verifier (address principal))
    (match (map-get? verifiers address)
        verified-map (get active verified-map)
        false
    )
)

(define-private (check-expiration (timestamp uint))
    (< timestamp block-height)
)

;; Public Functions
(define-public (register-identity (did (string-ascii 50)))
    (let
        (
            (existing-identity (map-get? identities tx-sender))
        )
        (asserts! (is-none existing-identity) err-already-exists)
        (ok (map-set identities tx-sender
            {
                did: did,
                status: "active",
                created-at: block-height,
                updated-at: block-height,
                verification-level: u0,
                recovery-address: none
            }
        ))
    )
)

(define-public (add-attribute (key (string-ascii 50)) (value (string-ascii 100)))
    (let
        (
            (existing-identity (map-get? identities tx-sender))
        )
        (asserts! (is-some existing-identity) err-not-found)
        (ok (map-set attributes {owner: tx-sender, key: key}
            {
                value: value,
                verified: false,
                verifier: none,
                timestamp: block-height,
                expiration: (+ block-height u52560) ;; Expires in ~365 days
            }
        ))
    )
)

(define-public (register-verifier (name (string-ascii 50)))
    (let
        (
            (existing-verifier (map-get? verifiers tx-sender))
        )
        (asserts! (is-none existing-verifier) err-already-exists)
        (ok (map-set verifiers tx-sender
            {
                name: name,
                verification-count: u0,
                active: true,
                trust-score: u80,
                join-date: block-height
            }
        ))
    )
)

(define-public (request-verification (attribute-key (string-ascii 50)))
    (let
        (
            (request-id (+ (var-get request-counter) u1))
            (existing-attribute (map-get? attributes {owner: tx-sender, key: attribute-key}))
        )
        (asserts! (is-some existing-attribute) err-not-found)
        (var-set request-counter request-id)
        (ok (map-set verification-requests request-id
            {
                requester: tx-sender,
                attribute-key: attribute-key,
                status: "pending",
                verifier: none,
                created-at: block-height,
                completed-at: none
            }
        ))
    )
)

(define-public (verify-attribute (request-id uint) (approved bool))
    (let
        (
            (request (unwrap! (map-get? verification-requests request-id) err-not-found))
            (verifier-data (unwrap! (map-get? verifiers tx-sender) err-unauthorized))
        )
        (asserts! (is-verifier tx-sender) err-unauthorized)
        (asserts! (is-eq (get status request) "pending") err-invalid-status)
        
        (if approved
            (map-set attributes 
                {owner: (get requester request), key: (get attribute-key request)}
                {
                    value: (get value (unwrap! (map-get? attributes {owner: (get requester request), key: (get attribute-key request)}) err-not-found)),
                    verified: true,
                    verifier: (some tx-sender),
                    timestamp: block-height,
                    expiration: (+ block-height u52560)
                }
            )
            false
        )
        
        (ok (map-set verification-requests request-id
            (merge request
                {
                    status: (if approved "approved" "rejected"),
                    verifier: (some tx-sender),
                    completed-at: (some block-height)
                }
            )
        ))
    )
)

;; Decentralized Attribute Schema Registry
(define-map schema-registry
    (string-ascii 50)  ;; schema-id
    {
        name: (string-ascii 100),
        version: (string-ascii 20),
        creator: principal,
        created-at: uint,
        updated-at: uint,
        status: (string-ascii 20),
        field-count: uint,
        required-verifier-score: uint
    }
)

(define-map schema-fields
    {
        schema-id: (string-ascii 50),
        field-name: (string-ascii 50)
    }
    {
        field-type: (string-ascii 20),
        required: bool,
        description: (string-ascii 200),
        validation-regex: (optional (string-ascii 100)),
        min-length: (optional uint),
        max-length: (optional uint)
    }
)

(define-map schema-endorsements
    (string-ascii 50)  ;; schema-id
    (list 100 principal)
)

(define-public (register-schema 
    (schema-id (string-ascii 50))
    (name (string-ascii 100))
    (version (string-ascii 20))
    (required-score uint))
    (let
        (
            (existing-schema (map-get? schema-registry schema-id))
        )
        (asserts! (is-none existing-schema) err-already-exists)
        (asserts! (is-verifier tx-sender) err-unauthorized)
        
        (ok (map-set schema-registry schema-id
            {
                name: name,
                version: version,
                creator: tx-sender,
                created-at: block-height,
                updated-at: block-height,
                status: "active",
                field-count: u0,
                required-verifier-score: required-score
            }))
    )
)

(define-public (add-schema-field
    (schema-id (string-ascii 50))
    (field-name (string-ascii 50))
    (field-type (string-ascii 20))
    (required bool)
    (description (string-ascii 200))
    (validation-regex (optional (string-ascii 100)))
    (min-length (optional uint))
    (max-length (optional uint)))
    (let
        (
            (schema (unwrap! (map-get? schema-registry schema-id) err-not-found))
        )
        (asserts! (is-eq (get creator schema) tx-sender) err-unauthorized)
        (asserts! (is-eq (get status schema) "active") err-invalid-status)
        
        ;; Update field count
        (map-set schema-registry schema-id
            (merge schema
                {
                    field-count: (+ (get field-count schema) u1),
                    updated-at: block-height
                }
            ))
        
        (ok (map-set schema-fields
            {
                schema-id: schema-id,
                field-name: field-name
            }
            {
                field-type: field-type,
                required: required,
                description: description,
                validation-regex: validation-regex,
                min-length: min-length,
                max-length: max-length
            }))
    )
)