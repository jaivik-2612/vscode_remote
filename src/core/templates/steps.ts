/**
 * Checkable sub-steps for every task of the deeply-authored (featured)
 * events, keyed by task id. Applied to the catalog in templates/index.ts.
 * Archetype-generated tasks carry their steps inline in builder.ts.
 *
 * Style: short, past-tense checkbox labels ("Flights booked"), 2–5 per task.
 */
export const TASK_STEPS: Record<string, string[]> = {
  /* ---- I moved ---- */
  'moved.mail_forwarding': ['Change-of-address filed', 'Start date set to move day', 'Confirmation received'],
  'moved.licence_address': ['Form / online update submitted', 'Fee paid', 'Updated licence received'],
  'moved.new_licence': ['Local requirements checked', 'Appointment booked', 'Documents brought & exchanged', 'New licence received'],
  'moved.voter_reregister': ['Registration submitted', 'Confirmation received'],
  'moved.tax_address': ['Tax authority notified', 'Confirmation received'],
  'moved.employer': ['HR / payroll notified', 'Withholding rechecked', 'Benefits mailing address updated'],
  'moved.banks': ['All accounts listed', 'Each bank updated', 'Cards & statements verified'],
  'moved.home_insurance': ['Insurer notified', 'New policy / transfer effective on move day', 'Old policy ended'],
  'moved.renters_insurance': ['Quotes compared', 'Policy active before key handover', 'Proof sent to landlord'],
  'moved.auto_insurance': ['Garaging address updated', 'New premium confirmed', 'New proof of insurance saved'],
  'moved.vehicle_address': ['Registry notified', 'Updated registration received'],
  'moved.vehicle_reregister': ['Local rules checked', 'Inspection passed (if required)', 'Re-registered', 'New plates received'],
  'moved.utilities_close': ['Final readings scheduled', 'Accounts closed / transferred', 'Final bills settled'],
  'moved.utilities_open': ['Providers chosen', 'Start dates booked for day one', 'First bills verified'],
  'moved.health_records': ['Insurer address updated', 'Network coverage checked', 'Prescriptions transferred', 'Records requested'],
  'moved.subscriptions': ['Recurring deliveries listed', 'Addresses updated', 'Local memberships switched'],

  /* ---- I started a business ---- */
  'biz.name_check': ['Registry searched', 'Trademark database searched', 'Name reserved'],
  'biz.register': ['Structure documents prepared', 'Registration filed', 'Certificate received'],
  'biz.tax_id': ['Application submitted', 'Tax ID received', 'Stored with key documents'],
  'biz.sales_tax': ['Obligation / threshold checked', 'Account registered', 'Filing schedule noted'],
  'biz.bank_account': ['Bank chosen', 'Account opened', 'Cards & online access set up'],
  'biz.licences': ['Requirements checked at all levels', 'Applications submitted', 'Licences received'],
  'biz.premises_licence': ['Zoning checked', 'Occupancy permit obtained', 'Signage permit obtained'],
  'biz.liability_insurance': ['Quotes obtained', 'Policy bound', 'Certificate of insurance saved'],
  'biz.premises_insurance': ['Coverage scoped', 'Policy active', 'Certificate saved'],
  'biz.employer_accounts': ['Withholding account opened', 'Unemployment insurance registered', 'Pension scheme registered'],
  'biz.payroll': ['Provider chosen', 'Pay schedule set', 'First payroll run verified'],
  'biz.workers_comp': ['Coverage requirement checked', 'Policy / board registration active', 'Certificate saved'],
  'biz.accounting': ['Software / accountant chosen', 'Chart of accounts set', 'Bank feed connected'],
  'biz.compliance_calendar': ['All obligations listed', 'Deadlines calendared', 'Reminders set'],

  /* ---- Immigrate to Canada ---- */
  'imm.eligibility': ['Criteria scored honestly', 'Pathway chosen', 'Score gaps identified'],
  'imm.language_test': ['Test booked', 'Preparation done', 'Test taken', 'Results received'],
  'imm.eca': ['Designated organization chosen', 'Transcripts sent by institution', 'ECA report received'],
  'imm.passport': ['Expiry dates checked', 'Renewals ordered if needed'],
  'imm.work_history': ['Employers listed with dates', 'Reference letters requested', 'Letters match NOC duties', 'Contracts & pay slips gathered'],
  'imm.police_certs': ['Countries listed (6+ months each)', 'Each certificate ordered', 'All certificates received'],
  'imm.proof_of_funds': ['Required amount confirmed', 'Bank letters ordered', 'Large deposits explained'],
  'imm.spouse_language': ['Cost vs. points weighed', 'Test booked & taken'],
  'imm.spouse_docs': ['Relationship proof gathered', 'Spouse ID & documents gathered'],
  'imm.job_offer_docs': ['Offer letter obtained', 'Employer compliance (LMIA / exemption) confirmed', 'Points impact verified'],
  'imm.profile': ['Profile created', 'Scores entered accurately', 'Profile submitted to pool'],
  'imm.medical': ['Panel physician booked', 'Exam completed', 'Confirmation saved'],
  'imm.application': ['Checklist items compiled', 'Forms completed', 'Fees paid', 'Submitted before deadline'],
  'imm.monitor': ['Account checked weekly', 'Biometrics completed', 'All requests answered in window'],

  /* ---- Got married ---- */
  'mar.certificate': ['Certified copies ordered', 'Copies received & stored'],
  'mar.tax_status': ['Tax authority notified', 'Withholding reviewed'],
  'mar.insurance': ['Spouse added to health plan in window', 'Auto / home bundles reviewed'],
  'mar.beneficiaries': ['Accounts & policies listed', 'Beneficiaries updated everywhere', 'Wills reviewed'],
  'mar.name_id': ['Passport updated', 'Licence updated', 'Social / tax ID updated'],
  'mar.name_everywhere': ['Banks updated', 'Employer updated', 'Remaining accounts updated'],
  'mar.joint_accounts': ['Approach agreed (joint / separate / hybrid)', 'Accounts opened or merged', 'Bills & autopays repointed'],
  'mar.spouse_status': ['Immigration implications checked', 'Sponsorship / status application started if needed'],

  /* ---- We had a baby ---- */
  'baby.birth_registration': ['Registration filed', 'Birth certificate ordered', 'Certificate received'],
  'baby.ssn': ['Application submitted', 'Number received & stored'],
  'baby.health_enrollment': ['Insurer notified in window', 'Child added to policy', 'Pediatrician chosen'],
  'baby.leave': ['Employer notified', 'Benefit claim filed', 'Payment schedule confirmed'],
  'baby.child_benefits': ['Eligibility checked', 'Application submitted', 'First payment received'],
  'baby.beneficiaries': ['Guardian named', 'Will updated', 'Beneficiaries updated'],
  'baby.parentage': ['Acknowledgment form signed', 'Filed with registry', 'Both parents on the certificate'],
  'baby.education_savings': ['Account type chosen', 'Account opened', 'Contribution schedule set'],

  /* ---- I turned 18 ---- */
  'a18.register_vote': ['Registration submitted', 'Confirmation received'],
  'a18.adult_id': ['Documents gathered', 'Application submitted', 'ID / passport received'],
  'a18.selective_service': ['Requirement checked', 'Registration completed', 'Proof saved'],
  'a18.own_bank': ['Account converted / opened', 'Online banking secured', 'Old custodial arrangement closed'],
  'a18.credit_start': ['Starter card / authorized-user set up', 'Autopay in full enabled'],
  'a18.health_admin': ['Registered with a doctor as an adult', 'Insurance status understood', 'Consent / proxy considered'],
  'a18.drivers_licence': ['Learner requirements checked', 'Theory test passed', 'Practical lessons booked'],
  'a18.student_aid': ['Aid deadlines listed', 'Applications prepared', 'Submitted on time'],

  /* ---- Graduated college ---- */
  'grad.documents': ['Transcripts ordered', 'Diploma copies ordered', 'Received & stored'],
  'grad.loan_inventory': ['Every loan listed', 'Servicers & rates noted', 'Grace-end dates calendared'],
  'grad.repayment_plan': ['Plan options compared', 'Plan selected before grace ends', 'First payment scheduled'],
  'grad.health_transition': ['Coverage end date confirmed', 'New coverage chosen', 'Active without a gap'],
  'grad.digital_migration': ['Files moved off university storage', 'Logins moved off .edu email', 'Forwarding enabled'],
  'grad.career_setup': ['Résumé updated with degree', 'Profiles updated', 'References locked in'],
  'grad.tax_status': ['Dependency status checked', 'Education credits claimed', 'Loan-interest deduction noted'],
  'grad.move_out': ['Move-out date confirmed', 'New address arranged', 'Deposits recovered'],

  /* ---- Bought a house ---- */
  'house.insurance': ['Quotes compared', 'Policy bound effective closing day', 'Proof sent to lender'],
  'house.title_deed': ['Deed recording verified', 'Title policy stored'],
  'house.property_tax': ['Tax account set up', 'Exemption filed', 'Billing route (escrow / direct) confirmed'],
  'house.utilities': ['Providers contacted', 'Transfers effective closing day', 'First bills verified'],
  'house.mortgage_autopay': ['Autopay set up', 'First payment date confirmed', 'First payment verified'],
  'house.escrow_check': ['Escrow statement reviewed', 'Tax & insurance coverage confirmed'],
  'house.first_time_benefits': ['Available programs listed', 'Claims / filings submitted', 'Benefits received'],
  'house.estate_update': ['Will updated with the property', 'Beneficiaries reviewed'],
  'house.old_home': ['Notice given / sale coordinated', 'Overlap dates planned', 'Deposits or proceeds settled'],
  'house.reno_before': ['Work scoped & quoted', 'Permits checked', 'Scheduled before move-in'],

  /* ---- Got divorced ---- */
  'div.decree_copies': ['Certified copies ordered', 'Copies received & stored'],
  'div.finances_split': ['Joint accounts listed', 'Accounts closed / retitled', 'Debts split per decree', 'Credit reports checked'],
  'div.beneficiaries': ['Policies & accounts listed', 'Every beneficiary updated', 'Emergency contacts updated'],
  'div.health_insurance': ['Coverage end date confirmed', 'Continuation / new coverage elected', 'Children\'s coverage settled'],
  'div.tax_status': ['Filing status updated', 'Withholding adjusted', 'Support payments treatment checked'],
  'div.custody_support': ['Parenting plan registered', 'Support order filed', 'School & doctors informed'],
  'div.name_change': ['Core ID updated', 'Banks & employer updated', 'Remaining accounts updated'],
  'div.estate_docs': ['Will rewritten', 'Powers of attorney replaced', 'Executor changed'],
  'div.home_division': ['Home valuation obtained', 'Buyout / sale decided', 'Title & mortgage retitled'],

  /* ---- Retired ---- */
  'ret.employer_notice': ['Final date agreed', 'Leave payout confirmed', 'Benefit conversions elected in window'],
  'ret.gov_pension': ['Claiming age decided', 'Application submitted', 'First payment confirmed'],
  'ret.employer_plan': ['Options compared', 'Decision executed', 'Confirmation received'],
  'ret.gov_health': ['Enrollment window confirmed', 'Enrolled', 'Card / confirmation received'],
  'ret.income_plan': ['Income sources mapped', 'Withdrawal order decided', 'Annual budget set'],
  'ret.tax_withholding': ['Withholding set on each income source', 'Instalments scheduled if needed'],
  'ret.estate_refresh': ['Will reviewed', 'Powers of attorney current', 'Beneficiaries verified'],
  'ret.parttime_tax': ['Earnings limits checked', 'Benefit clawback rules understood', 'Withholding adjusted'],

  /* ---- New job ---- */
  'job.contract': ['Contract reviewed & signed', 'Covenants understood', 'Onboarding documents ready'],
  'job.tax_forms': ['Withholding forms submitted', 'Allowances double-checked'],
  'job.benefits_enrollment': ['Options compared', 'Elections submitted in window', 'Confirmation saved'],
  'job.retirement_enroll': ['Enrolled in plan', 'Contribution captures full match', 'Investments selected'],
  'job.old_retirement': ['Options compared', 'Rollover / decision executed', 'Old account confirmed handled'],
  'job.coverage_bridge': ['Old end date confirmed', 'New start date confirmed', 'Gap closed if any'],
  'job.payroll_check': ['Gross pay verified', 'Withholding verified', 'Deductions verified'],
  'job.relocation': ['Employer contribution confirmed in writing', 'Housing plan made', 'Move scheduled'],

  /* ---- Lost job ---- */
  'loss.unemployment_claim': ['Claim filed', 'Documents submitted', 'First payment confirmed'],
  'loss.severance_review': ['Agreement read fully', 'Professional review done', 'Signed or negotiated'],
  'loss.health_continuation': ['Options compared', 'Election made in window', 'Coverage confirmed active'],
  'loss.budget_triage': ['Fixed obligations listed', 'Non-essentials cut', 'Runway calculated'],
  'loss.retirement_protect': ['Cash-out avoided', 'Leave / rollover decided', 'Executed'],
  'loss.employer_records': ['Termination letter obtained', 'Pay history obtained', 'References confirmed'],
  'loss.hardship_relief': ['Lender hardship programs contacted', 'Deferrals arranged', 'Assistance programs applied for'],
  'loss.convert_policies': ['Employer policies listed', 'Conversion deadlines checked', 'Policies converted or replaced'],

  /* ---- Bought a car ---- */
  'car.insurance': ['Quotes compared', 'Policy active before pickup', 'Proof of insurance in hand'],
  'car.title_registration': ['Title transferred', 'Registration completed', 'Plates received'],
  'car.inspection': ['Inspection booked', 'Passed', 'Certificate saved'],
  'car.loan_setup': ['Autopay set up', 'Lien recorded correctly'],
  'car.sales_tax': ['Amount confirmed', 'Paid at registration'],
  'car.old_car': ['Old vehicle sold / traded / transferred', 'Old registration cancelled', 'Old insurance ended without a gap'],

  /* ---- A loved one passed away ---- */
  'est.death_certificates': ['8–10 certified copies ordered', 'Copies received'],
  'est.notify_agencies': ['Social security / pension notified', 'Tax authority notified', 'Licence & electoral records closed'],
  'est.will_probate': ['Will located', 'Probate filed', 'Letters of administration received'],
  'est.banks_freeze': ['Banks notified', 'Sole accounts frozen', 'Bouncing autopayments stopped'],
  'est.estate_account': ['Account opened', 'Estate transactions routed through it'],
  'est.insurance_claims': ['Policies & benefits listed', 'Claims filed', 'Payouts received'],
  'est.subscriptions': ['Accounts found via statements', 'Each closed or transferred'],
  'est.final_taxes': ['Records gathered', 'Final return filed', 'Estate return filed if needed'],
  'est.funeral': ['Wishes / prepaid plan checked', 'Funeral home chosen', 'Service arranged', 'Costs settled'],
  'est.property': ['Property secured', 'Insurer notified (vacancy rules)', 'Mortgage servicer notified'],

  /* ---- Trip abroad ---- */
  'trip.passports': ['Every passport checked (6+ months)', 'Renewals submitted if needed', 'Passports received'],
  'trip.visas': ['Requirements checked per country', 'Applications submitted', 'Visas / authorizations received'],
  'trip.minor_docs': ['Child passports valid', 'Consent letter notarized', 'Birth certificates packed'],
  'trip.insurance': ['Policies compared', 'All travelers covered', 'Policy saved offline'],
  'trip.bookings': ['Flight tickets booked', 'Hotel stay confirmed', 'Tour guide confirmed', 'Names match passports', 'Confirmations saved'],
  'trip.health_prep': ['Vaccinations checked & done', 'Prescriptions packed in original packaging', 'Scripts copied'],
  'trip.money': ['Bank travel notice set', 'Backup card packed', 'Roaming / eSIM arranged', 'Some local currency obtained'],
  'trip.house_sitting': ['Sitter / boarding booked', 'Keys & vet contacts shared', 'Mail held & deliveries paused'],
  'trip.car_rental': ['Rental car booked', 'International Driving Permit obtained', 'Rental insurance sorted'],
  'trip.work_prep': ['Coverage briefed', 'Out-of-office set', 'Urgent items closed'],

  /* ---- New pet ---- */
  'pet.vet_registration': ['Vet chosen & registered', 'First check-up done', 'Vaccination schedule started'],
  'pet.microchip': ['Chip implanted', 'Registry updated with your contacts'],
  'pet.licence': ['Requirement checked', 'Licence obtained', 'Tag attached'],
  'pet.insurance': ['Quotes compared', 'Decision made', 'Policy active if chosen'],
  'pet.household': ['Lease / bylaws checked', 'Home pet-proofed', 'Supplies bought'],
  'pet.training': ['Training approach chosen', 'Classes booked', 'Daily routine established'],
  'pet.care_plan': ['Sitter / boarding options vetted', 'Backup carer agreed', 'Care instructions written'],

  /* ---- Home renovation ---- */
  'reno.scope_budget': ['Scope written', 'Budget itemized', 'Contingency added'],
  'reno.permits': ['Requirements checked', 'Application submitted', 'Permits received'],
  'reno.contractor': ['Licence & insurance verified', 'Contract signed', 'Payment schedule tied to milestones'],
  'reno.insurance_notify': ['Insurer notified', 'Rider added if needed', 'Post-work value update planned'],
  'reno.financing': ['Options compared', 'Financing confirmed', 'Draw schedule aligned with payments'],
  'reno.inspections': ['Required inspections listed', 'Each stage inspected', 'Final sign-off received'],
  'reno.temp_housing': ['Housing booked', 'Dates aligned with work schedule', 'Budget updated'],
};
