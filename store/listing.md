# App Store listing

Everything App Store Connect asks for, ready to paste. Screenshots are in
`store/screenshots/` (6.9", 1320×2868), made by `tool/store_shots.py`.
Apple scales them down for smaller iPhones, so no other sizes are needed.

## App information

| Field | Value |
|---|---|
| Name (30) | **Mull: Split Bills & Settle** (if "Mull" alone is free, take it) |
| Subtitle (30) | **Split bills, settle over UPI** |
| Bundle ID | in.mull.app |
| SKU | mull-ios-1 |
| Primary category | Finance |
| Secondary category | Lifestyle |
| Content rights | Does not contain third-party content |
| Copyright | 2026 Dilip Khanna |
| Price | Free |
| Availability | **India only** (Pricing and Availability → deselect all, tick India) |

## URLs

| Field | Value |
|---|---|
| Privacy Policy URL | https://mull.oblunestudio.com/privacy.html |
| Support URL | https://mull.oblunestudio.com/support.html |
| Marketing URL | https://mull.oblunestudio.com |

## Promotional text (170)

Split rent, trips and dinners with the people you actually share money with. One number per person, payments that get confirmed, and UPI in a tap.

## Description

Mull keeps track of shared money with the people you live, travel and eat with, and settles it over UPI.

Add an expense, pick who paid and how to split it: equally, by exact amounts, by shares or by percentage. Mull works out who owes whom, and the fewest payments that clear a group.

ONE NUMBER PER PERSON
Owe Ananya for the trip while she owes you for the flat? That is one fact, not two. Mull shows what is actually left between you, and can net the two off so both ledgers are square without anyone sending money.

PAYMENTS ARE CONFIRMED, NOT ASSUMED
When you pay someone back, they confirm it arrived before any balance moves. No more "I already sent it" arguments, and no balance that is quietly wrong forever.

BILLS THAT REPEAT, AND ASK
Rent, the maid, the Wi-Fi. Set them up once. When one is due, Mull asks you first, with the amount ready to change, because rent goes up and people move out.

SETTLE IN A TAP
Pay opens your UPI app with the amount and the person filled in. Mull never touches your money.

ALSO
• Groups for the flat, a trip, the Sunday football, and one-to-one ledgers for everything else
• Add people who are not on Mull yet and split with them tonight
• Gentle reminders, capped so nobody gets nagged
• Notifications when someone adds an expense or pays you
• Dark and light themes

No ads. No tracking. Your data is not sold.

## Keywords (100)

split,bills,expenses,upi,roommates,flatmates,trip,rent,owe,friends,group,settle,share,ledger,dinner

(No competitor or payment-app names: Apple rejects keywords that use other companies' trademarks.)

## What's new (for later versions)

First release.

## Age rating

Answer **None / No** to every question. Result: **4+**.

- Unrestricted web access: No (links open only Mull's own pages).
- User-generated content: **Yes, to be safe.** Expense names and notes are seen by the people you share a group with. Apple's rule for this (guideline 1.2) wants a way to report and block people, and Mull has both: Friends → ··· → Report / Block. Reports land in the `reports` table; during review and after launch, check it daily (Supabase → Table editor → reports, status = open) and act within 24 hours.
- Messaging and chat: No (reminders are fixed, app-written messages).
- Gambling, contests, medical info and so on: No.

## App Privacy ("nutrition label")

Tracking: **No, we do not use data for tracking.**

| Data type | Collected | Linked to user | Tracking | Purpose |
|---|---|---|---|---|
| Contact Info → Name | Yes | Yes | No | App Functionality |
| Contact Info → Email Address | Yes | Yes | No | App Functionality |
| Contact Info → Phone Number | Yes (only if typed in to invite someone) | Yes | No | App Functionality |
| Identifiers → User ID (the account id) | Yes | Yes | No | App Functionality |
| Financial Info → Other Financial Info (UPI ID) | Yes | Yes | No | App Functionality |
| User Content → Other User Content (expenses, groups) | Yes | Yes | No | App Functionality |
| Diagnostics → Crash Data | Yes | **No** | No | App Functionality |

Everything else: not collected. This matches `ios/Runner/PrivacyInfo.xcprivacy`
and `site/privacy.html`. Change all three together.

## App Review information

- Sign-in required: **Yes**
- User name: `review@mull.oblunestudio.com`
- Password: printed by `./tool/review-account.sh` (kept in `.secrets/review-account`)
- Contact: Bharat Khanna, mullapp.official@gmail.com, your phone number

Notes (paste):

> Mull signs people in with a one-time code sent by email. For review, enter review@mull.oblunestudio.com on the sign-in screen. No email is sent: enter the password above where the app asks for the review code.
>
> The account has three demo ledgers. "Goa trip" has a payment from Kabir waiting to be confirmed (tap Check on the home screen). "Flat 302" has monthly rent that is due today and asks before it is added. "Meera" is a one-to-one ledger.
>
> Mull never processes payments. "Pay" opens the device's UPI app (Google Pay, PhonePe and so on) with the details filled in, and the payment happens there. The demo people's UPI IDs end in @example, which no bank issues, so nothing can actually be paid.
>
> Account deletion: profile (top right) → Delete account.
>
> Reporting and blocking: Friends (the people icon, top right) → ··· next to a person → Report or Block. Reports go to our moderation queue, and we review them within 24 hours.

## TestFlight

Beta App Description:

> Mull splits shared money with friends, flatmates and trips, and settles it over UPI. Thank you for testing!

What to test:

> Make a group with someone else who is testing, add a few expenses, and pay each other back over UPI. Try GPay, PhonePe and Paytm if you have them, and tell us which ones open correctly. Check you get a notification when the other person adds an expense or pays you. Anything confusing or broken: shake the phone to send feedback, or email mullapp.official@gmail.com.

Feedback email: mullapp.official@gmail.com
