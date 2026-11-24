# Concurrency test guide
**Status:** scripts written, NOT yet run. Record your results in the table below after running them.

## Automated
`npm install`, then run `npm run test:booking` (needs a customer login, an approved business and an active service; env vars are in the file header).
Checks: (1) 20 parallel bookings give 20 unique tokens, (2) 10 identical requests (same idempotency key) give 1 booking, (3) two requests for the same appointment slot give exactly 1 success.
`npm run test:queue` checks illegal transitions are rejected.

## Manual (good for a live demo)
1. Open the customer page in 2 browsers (2 accounts). Click "Confirm booking" at the same moment: tokens differ.
2. Double-click "Confirm booking" quickly: only one booking appears.
3. Open the staff queue in 2 browsers and click "Call next" together: two different customers are called, never the same one.
4. Staff A clicks Complete on a Waiting row (stale screen): the database rejects it.

## Results
| Test | Date | Result |
|---|---|---|
| booking-tests | | |
| queue-tests | | |
