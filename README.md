# FlashCart Finance & Kit Recovery Integration — v1

## Included source files
- `Customer/lib/main.dart`: original customer app source, unchanged.
- `CEO/lib/main.dart`: CEO finance control added to existing CEO app.
- `Admin/lib/main.dart`: COD cash handover, Razorpay link and admin monthly earnings UI added.
- `DeliveryPartner/lib/main.dart`: Partner kit consent, recovery ledger and COD cash handover UI added.
- `firestore.rules`: existing rules plus scoped finance/recovery rules.
- `functions/index.js`: callable Razorpay key storage, COD payment-link generation, webhook and monthly admin earning generation.
- `pubspec.yaml`: dependency additions needed by the supplied sources.

## Important implementation limits
1. The uploaded sources were pasted Dart files, not a complete Flutter workspace. Android/iOS/web project folders, each app's separate `pubspec.yaml`, Firebase Functions current folder, and the current deployed Firebase configuration were not included.
2. No Flutter/Dart SDK build or Firebase Emulator test could be run in this environment. Treat this as an integration patch package, not a production-tested release.
3. Kit recovery is deliberately queued for the next settlement. It does not directly mutate historical earnings or make an automatic deduction. A trusted settlement function still needs to be connected to your existing weekly payout flow before any queued amount is deducted.
4. Admin monthly earnings currently use CEO-configured fixed monthly amount per branch. On the 2nd day of each month, the scheduled function creates the previous month's earning record. CEO must transfer money through bank/RazorpayX manually and then enter the UTR in CEO App to mark paid. Razorpay Payment Links are collection links, not payouts.
5. COD flow: Partner submits a cash handover → Admin confirms physical receipt → Admin creates Razorpay Payment Link for received cash → Razorpay webhook marks it `pending_ceo_verification` → CEO verifies it.
6. Razorpay Secret Key is not stored in Firestore or Flutter. CEO screen sends it to a callable backend, which writes it to Google Secret Manager. Enable Secret Manager IAM permissions for the Functions runtime service account (`roles/secretmanager.admin`) before using the CEO key-save screen.
7. The webhook secret is intentionally separate. Set it with Firebase CLI and configure the Razorpay webhook URL after deploying functions.

## Setup order
1. Back up all current app source files and current Firestore Rules.
2. Replace the corresponding `lib/main.dart` files with the supplied CEO/Admin/DeliveryPartner files. Keep Customer source unchanged.
3. Merge the supplied dependency additions into each app's own `pubspec.yaml` (do not overwrite app-specific dependencies blindly).
4. Install Functions dependencies:
   `cd functions && npm install`
5. Set webhook secret:
   `firebase functions:secrets:set RAZORPAY_WEBHOOK_SECRET`
   Enter the webhook secret from Razorpay Dashboard in the terminal prompt. Never paste it into chat or Dart.
6. Deploy Functions:
   `firebase deploy --only functions`
7. Publish `firestore.rules` only after reviewing it against the currently deployed rules and testing with Firebase Emulator. This package includes the uploaded rules plus new finance paths; compare with the live console version first.
8. Set the Functions runtime service account's Secret Manager permissions so it can create/read secrets. The CEO `Save Securely in Backend` action stores the two Razorpay keys.
9. Configure Razorpay webhook endpoint to:
   `https://asia-south1-sudhir2006-32c75.cloudfunctions.net/razorpayWebhook`
   Subscribe to `payment_link.paid`; use the same webhook secret you set in step 5.
10. Start with Razorpay Test Mode. Switch to Live only after successful test payments and webhook verification.

## Firestore collections introduced
- `kitCatalog`
- `kitRecoveryPlans`
- `kitRecoveryConsents`
- `partnerRecoveryLedger`
- `adminPayoutPolicy`
- `adminMonthlyEarnings`
- `codPaymentLinks`

Existing collections reused:
- `codCashHandovers`
- `codBankDeposits`
- `appConfig/financePolicy`
- `appConfig/paymentGateway`

## Business rules encoded
- Recovery percentage base is `delivery` earnings only.
- CEO sets a custom maximum per settlement.
- Kit policy is `mixed` (mandatory + optional).
- No recovery entry without partner's digital consent.
- COD payer responsibility is both: partner hands cash to branch Admin; Admin pays company.
- COD deadline is CEO-configurable.
- Admin payout day is the 2nd of every month.
- COD, Admin earnings, Partner earnings and Kit Recovery remain separate ledgers.

## Before production
- Confirm legal terms and worker/partner classification; obtain clear consent before any deductions.
- Add the queued kit recovery ledger to the trusted weekly settlement transaction with idempotency and balance checks.
- Test role access and queries in Firebase Emulator.
- Configure and test Razorpay webhook signature, duplicate event handling, payment failure/expiry, partial payment policy (currently disabled), and branch reconciliation.
- Do not upload Firebase service-account JSON, signing keys, Razorpay secrets or private credentials into this ZIP.
