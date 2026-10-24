# Paywallex pour iPhone

Kit officiel Paywallex pour iOS 13 ou plus récent (Swift). Il ouvre la page Paywallex dans la session navigateur du système (ASWebAuthenticationSession), qui garde la connexion Paywallex de Safari. La personne paie avec son compte en un geste ou avec Mobile Money, puis revient dans votre app.

> Avant de livrer une commande, confirmez toujours depuis votre serveur (webhook `payment.succeeded` ou API `/v1`). Le retour dans l'app seul ne prouve rien.

## Installation

Dans Xcode, choisissez File, Add Package Dependencies, puis collez l'adresse du dépôt :

```text
https://github.com/Paywallex/paywallex-ios
```

Choisissez la version 1.0.0 ou plus récente. Déclarez ensuite votre schéma dans `Info.plist` (`CFBundleURLTypes`, puis `CFBundleURLSchemes` : `monapp`).

## Encaisser un paiement

Le Labs, rubrique **Connecter une app**, vous donne la clé publique de l'app (`pxa_test_…` ou `pxa_live_…`) et l'adresse de l'API.

Créez le client, puis lancez le paiement :

```swift
import Paywallex

let paywallex = Paywallex(appKey: "pxa_test_…",
                          baseUrl: URL(string: "https://api.paywallx.xyz")!,
                          returnUrl: URL(string: "monapp://paiement")!)

let result = try await paywallex.pay(amount: "5000", reference: "CMD-1042", title: "Commande 1042")
if result.outcome == .paid { /* afficher « Merci » */ }
```

`outcome` vaut `.paid`, `.pending` (réessayez avec `status(reference:)`), `.failed`, `.expired` ou `.cancelled`.

## Abonner une personne

Un abonnement se crée toujours depuis votre serveur avec votre clé secrète (`POST /v1/subscriptions`, avec `success_url` et `cancel_url` égaux à l'adresse de retour de l'app). Votre serveur renvoie `subscribe_url` à l'app, qui l'ouvre avec le kit. Avant d'ouvrir l'accès, votre serveur vérifie l'abonnement (`GET /v1/subscriptions/{id}`).

Ouvrez le lien dans l'app :

```swift
let r = try await paywallex.subscribe(subscribeUrl: subscribeUrl)
if r.outcome == .returned, let id = r.subscriptionId { /* envoyez id à votre serveur */ }
```

« Gérer mon abonnement » : `try await paywallex.manageSubscription(manageUrl:)` avec le lien de `POST /v1/subscriptions/{id}/manage_link`.

## Licence

MIT.
