import SwiftUI

nonisolated struct SponsorOffer: Decodable, Identifiable, Sendable {
    struct Window: Decodable, Sendable { let minutes: Int; let creditCapMicros: Int }
    let offerId: String
    let sponsorName: String
    let category: String
    let paidForBy: String
    let disclosure: String
    let reportUrl: String
    let whyShown: String
    let windows: [Window]
    var id: String { offerId }
    func validate() throws {
        guard !offerId.isEmpty, offerId.utf8.count <= 200, !sponsorName.isEmpty, sponsorName.utf8.count <= 500,
              ["democratic_candidate", "democratic_issue"].contains(category), !paidForBy.isEmpty,
              disclosure.utf8.count <= 5000, whyShown.utf8.count <= 2000,
              let url = URL(string: reportUrl), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              !windows.isEmpty, windows.count <= 6, Set(windows.map(\.minutes)).count == windows.count,
              windows.allSatisfy({ [30,120,240,480,720,1440].contains($0.minutes) && $0.creditCapMicros > 0 && $0.creditCapMicros <= 9_007_199_254_740_991 }) else { throw GatewayError.invalidResponse }
    }
}
nonisolated struct SponsorWindowReceipt: Decodable, Sendable {
    let windowId: String
    let expiresAt: Int64
    let creditCapMicros: Int
    let remainingMicros: Int
    var expiry: Date { Date(timeIntervalSince1970: Double(expiresAt) / 1000) }
}
@MainActor enum SponsorshipAdapter {
    static func offers(_ account: AccountService) async throws -> [SponsorOffer] {
        nonisolated struct Reply: Decodable, Sendable { let offers: [SponsorOffer] }
        let reply: Reply = try await account.authenticatedRequest("GET", path: "/v1/sponsorship/offers")
        guard reply.offers.count <= 50, Set(reply.offers.map(\.id)).count == reply.offers.count else { throw GatewayError.invalidResponse }
        try reply.offers.forEach { try $0.validate() }
        return reply.offers
    }
    static func activate(_ offer: SponsorOffer, window: SponsorOffer.Window, account: AccountService) async throws -> SponsorWindowReceipt {
        try offer.validate()
        guard offer.windows.contains(where: { $0.minutes == window.minutes && $0.creditCapMicros == window.creditCapMicros }) else { throw GatewayError.invalidInput }
        nonisolated struct Input: Encodable { let offerId: String; let minutes: Int }
        let receipt: SponsorWindowReceipt = try await account.authenticatedRequest("POST", path: "/v1/sponsorship/windows", body: GatewayClient.encode(Input(offerId: offer.id, minutes: window.minutes)))
        guard !receipt.windowId.isEmpty, receipt.creditCapMicros == window.creditCapMicros, receipt.remainingMicros == receipt.creditCapMicros,
              receipt.expiry > Date(), receipt.expiry.timeIntervalSinceNow <= Double(window.minutes * 60 + 60) else { throw GatewayError.invalidResponse }
        return receipt
    }
    static func action(_ offer: SponsorOffer, reason: String?, account: AccountService) async throws {
        nonisolated struct Input: Encodable { let offerId: String; let reason: String? }
        nonisolated struct Reply: Decodable, Sendable { let ok: Bool }
        if let reason { guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.utf16.count <= 1000 else { throw GatewayError.invalidInput } }
        let reply: Reply = try await account.authenticatedRequest("POST", path: reason == nil ? "/v1/sponsorship/dismiss" : "/v1/sponsorship/report", body: GatewayClient.encode(Input(offerId: offer.id, reason: reason)))
        guard reply.ok else { throw GatewayError.invalidResponse }
    }
}
struct SponsorshipSheet: View {
    var account: AccountService
    @Environment(\.dismiss) private var dismiss
    @State private var offers: [SponsorOffer] = []
    @State private var receipt: SponsorWindowReceipt?
    @State private var selectedOffer: SponsorOffer?
    @State private var reportReason = ""
    @State private var notice: String?
    @State private var loading = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Optional sponsorship is available only when approved inventory has real funding and your prepaid credit is exhausted. It has a time limit and a finite allowance.")
                    Text("No photos, location or inferred political beliefs are used to select these offers. You can keep editing without accepting an offer.").font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView("Checking funded offers") }
                if offers.isEmpty && !loading { ContentUnavailableView("No funded offers available", systemImage: "tray", description: Text("No sponsorship or subsidy has been applied.")) }
                ForEach(offers) { offer in
                    Section("Advertisement · \(offer.sponsorName)") {
                        Text(offer.paidForBy).font(.headline)
                        Text(offer.disclosure)
                        Text("Why shown: \(offer.whyShown)").font(.caption)
                        ForEach(offer.windows, id: \.minutes) { window in
                            Button("Choose \(duration(window.minutes)) · up to \(CreditDisplay.usd(window.creditCapMicros))") {
                                run {
                                    receipt = try await SponsorshipAdapter.activate(offer, window: window, account: account)
                                    notice = "The server reserved this finite window. Future quotes still require your approval."
                                }
                            }.disabled(account.isBusy)
                        }
                        Button("Dismiss this offer") { run { try await SponsorshipAdapter.action(offer, reason: nil, account: account); offers.removeAll { $0.id == offer.id } } }.disabled(account.isBusy)
                        Button("Report this offer…") { selectedOffer = offer; reportReason = "" }
                        if let url = URL(string: offer.reportUrl) { Link("Sponsor reporting information", destination: url) }
                    }
                }
                if let receipt {
                    Section("Confirmed window receipt") {
                        LabeledContent("Maximum funded allowance", value: CreditDisplay.usd(receipt.creditCapMicros))
                        Text("Expires \(receipt.expiry.formatted()). This receipt is not a live remaining-balance display. Every quote is checked against the remaining funded amount.").font(.caption)
                    }
                }
                if let notice { Text(notice).font(.callout) }
            }.formStyle(.grouped).navigationTitle("Optional sponsorship").toolbar { Button("Done") { dismiss() } }
                .task { loading = true; defer { loading = false }; do { offers = try await SponsorshipAdapter.offers(account) } catch { notice = error.localizedDescription } }
                .sheet(item: $selectedOffer) { offer in
                    NavigationStack {
                        Form {
                            Text("Report \(offer.sponsorName)")
                            TextField("Reason", text: $reportReason, axis: .vertical).lineLimit(3...8)
                            Button("Send report") { run { try await SponsorshipAdapter.action(offer, reason: reportReason, account: account); selectedOffer = nil; notice = "Your report was recorded by the account service." } }.disabled(reportReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.isBusy)
                        }.navigationTitle("Report sponsorship").toolbar { Button("Cancel") { selectedOffer = nil } }
                    }.frame(minWidth: 300, minHeight: 300)
                }
        }.frame(minWidth: 320, minHeight: 480)
    }
    private func duration(_ minutes: Int) -> String { minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hours" }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) { Task { do { try await operation() } catch { notice = error.localizedDescription } } }
}
