# Sponsor operations

Sponsorship is disabled by absence of inventory. This repository contains no campaign, candidate, advertiser, endorsement, budget commitment or funding seed. Automated tests use clearly synthetic rows in disposable local D1 only.

An authorized operator must independently verify eligibility as an approved Democratic candidate or Democratic issue sponsor, the entity responsible for payment, disclosure, public reporting destination, finite funds actually committed, allowed durations and credit caps. Approval does not authorize political inference or behavioral targeting.

Create an initially paused `sponsors` row, paused `sponsor_offers` row, and explicit `sponsor_offer_windows` caps in an authorized production database workflow. Keep customer balances separate. Never populate a budget merely to demonstrate the feature. Activate only after approval and funding are recorded. Public routes cannot create or approve inventory.

The gateway reserves a whole window cap atomically from the sponsor pool. Window expiry returns unused funds once; in-flight job debits remain reserved until success or a refund to the original source. A paused/ended sponsor or offer cannot fund newly accepted jobs. Existing customer projects and paid-editor functionality remain available without sponsorship.

Before enabling, independently test last-credit races, approval withdrawal, expiry/reclaim, post-expiry failures, duplicated refunds and account deletion. Inspect sponsor budget plus window balances plus successful spend for conservation. Do not reclaim an in-flight reservation twice or transfer sponsor credit into a customer balance.
