// Paywallex pour iPhone (v1.0.0, DV4) : paiement, abonnement, retour dans l'app, confirmation serveur. Ouvre la page de paiement dans une session navigateur du système
// (ASWebAuthenticationSession), qui partage la connexion Paywallex de Safari : la personne paie avec son compte
// en un geste (App Switch) puis revient dans l'app par votre schéma (monapp://…).
// Le résultat est toujours confirmé auprès de Paywallex (/connect/status) : l'adresse de retour seule ne prouve rien.
import AuthenticationServices
import Foundation
import UIKit

public enum PaywallexOutcome: String { case paid, pending, failed, expired, cancelled }

public struct PaywallexResult {
    public let outcome: PaywallexOutcome
    public let reference: String
    public let amountMinor: String?
    public let currency: String?
    public let paymentId: String?
}

public enum PaywallexSubscribeOutcome: String { case returned, cancelled }

public struct PaywallexSubscribeResult {
    public let outcome: PaywallexSubscribeOutcome
    /// Identifiant de l'abonnement : votre serveur le vérifie (GET /v1/subscriptions/{id}) avant d'ouvrir l'accès.
    public let subscriptionId: String?
}

public enum PaywallexError: Error, LocalizedError {
    case invalidConfiguration(String)
    case server(code: String, message: String)
    case network(Error)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let m): return m
        case .server(_, let m): return m
        case .network(let e): return e.localizedDescription
        }
    }
}

@MainActor
public final class Paywallex: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// - Parameters:
    ///   - appKey: clé publique de l'app connectée (pxa_test_… en bac à sable, pxa_live_… en production).
    ///   - baseUrl: adresse de l'API Paywallex, sans « /api » (donnée dans le Labs).
    ///   - returnUrl: adresse de retour déclarée dans la fiche de l'app, ex. « monapp://paiement ».
    public init(appKey: String, baseUrl: URL, returnUrl: URL) {
        self.appKey = appKey; self.baseUrl = baseUrl; self.returnUrl = returnUrl
    }
    private let appKey: String, baseUrl: URL, returnUrl: URL
    private var session: ASWebAuthenticationSession?

    /// Crée le paiement, ouvre la page Paywallex et rend le résultat confirmé par le serveur.
    /// - Parameters:
    ///   - amount: montant en unités entières de la devise du compte (ex. « 5000 » pour 5 000 F CFA).
    ///   - reference: votre numéro de commande, unique (lettres, chiffres, . _ : -, 80 caractères au plus).
    public func pay(amount: String, reference: String, title: String? = nil) async throws -> PaywallexResult {
        guard let scheme = returnUrl.scheme, !["http", "https"].contains(scheme.lowercased()) else {
            throw PaywallexError.invalidConfiguration("returnUrl doit utiliser le schéma de votre app (ex. monapp://paiement).")
        }
        var body: [String: String] = ["app": appKey, "amount": amount, "ref": reference, "return": returnUrl.absoluteString]
        if let title { body["title"] = title }
        let created: [String: Any] = try await request("POST", "/api/connect/pay", body: body)
        guard let s = created["url"] as? String, let url = URL(string: s) else {
            throw PaywallexError.server(code: "invalid_response", message: "Réponse Paywallex inattendue.")
        }
        let back = await open(url, scheme: scheme)
        return try await status(reference: reference, hint: back.flatMap { Self.query($0, "paywallex_status") } ?? "cancelled")
    }

    /// Ouvre le lien d'abonnement créé par VOTRE SERVEUR (POST /v1/subscriptions avec success_url et cancel_url = returnUrl).
    /// Rend `.returned` avec l'identifiant de l'abonnement quand la personne revient après avoir accepté, `.cancelled` sinon.
    public func subscribe(subscribeUrl: URL) async throws -> PaywallexSubscribeResult {
        let back = try await openPaywallexPage(subscribeUrl)
        if let id = back.flatMap({ Self.query($0, "subscription_id") }), !id.isEmpty {
            return PaywallexSubscribeResult(outcome: .returned, subscriptionId: id)
        }
        return PaywallexSubscribeResult(outcome: .cancelled, subscriptionId: nil)
    }

    /// Ouvre « Gérer mon abonnement » (lien de POST /v1/subscriptions/{id}/manage_link, valable 1 h) et attend le retour.
    public func manageSubscription(manageUrl: URL) async throws { _ = try await openPaywallexPage(manageUrl) }

    private func openPaywallexPage(_ url: URL) async throws -> URL? {
        guard let scheme = returnUrl.scheme, !["http", "https"].contains(scheme.lowercased()) else {
            throw PaywallexError.invalidConfiguration("returnUrl doit utiliser le schéma de votre app (ex. monapp://paiement).")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw PaywallexError.invalidConfiguration("Le lien doit être une adresse Paywallex en https.")
        }
        return await open(url, scheme: scheme)
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value
    }

    /// Confirme l'état d'un paiement auprès de Paywallex (à refaire côté serveur avant de livrer).
    public func status(reference: String, hint: String? = nil) async throws -> PaywallexResult {
        var c = URLComponents(url: baseUrl.appendingPathComponent("api/connect/status"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "app", value: appKey), URLQueryItem(name: "ref", value: reference)]
        let j: [String: Any] = try await request("GET", c.url!, body: nil)
        let st = j["status"] as? String ?? "not_found"
        let outcome: PaywallexOutcome
        switch st {
        case "paid": outcome = .paid
        case "expired": outcome = .expired
        default: outcome = hint == "cancelled" ? .cancelled : hint == "failed" ? .failed : .pending
        }
        return PaywallexResult(outcome: outcome, reference: reference, amountMinor: j["amountMinor"] as? String,
                               currency: j["currency"] as? String, paymentId: j["paymentId"] as? String)
    }

    private func open(_ url: URL, scheme: String) async -> URL? {
        await withCheckedContinuation { (k: CheckedContinuation<URL?, Never>) in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { cb, _ in
                // Fermeture par la personne : cb vaut nil, on confirme quand même auprès du serveur.
                k.resume(returning: cb)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false // garde la connexion Paywallex de Safari (App Switch)
            self.session = s
            if !s.start() { k.resume(returning: nil) }
        }
    }

    private func request(_ method: String, _ path: String, body: [String: String]?) async throws -> [String: Any] {
        try await request(method, baseUrl.appendingPathComponent(String(path.dropFirst())), body: body)
    }

    private func request(_ method: String, _ url: URL, body: [String: String]?) async throws -> [String: Any] {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method
        r.setValue("ios/1.0.0", forHTTPHeaderField: "Paywallex-Sdk")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: r) } catch { throw PaywallexError.network(error) }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw PaywallexError.server(code: j["code"] as? String ?? "http_\(h.statusCode)",
                                        message: j["error"] as? String ?? "Paiement indisponible.")
        }
        return j
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }
}
