import Attribr

/// Reference integration pattern for consumer apps: wrap Attribr calls in your
/// own @MainActor type. Compiling this file IS the test — if Attribr's public
/// API ever becomes callable from a non-main-actor context in a way this
/// example no longer needs, or if it grows a new entry point this example
/// should demonstrate, update this file accordingly.
@MainActor
enum AttribrWrapper {
    static func start(apiKey: String) {
        Attribr.initialize(apiKey: apiKey)
        Attribr.setConsent(.granted)
        Attribr.trackLaunch()
    }

    static func trackPurchase(productId: String, amount: Double, transactionId: String) {
        Attribr.trackRevenue(
            amount: amount,
            currency: "USD",
            productId: productId,
            transactionId: transactionId
        )
        Attribr.updateConversionValue(eventName: "purchase", value: amount)
    }
}
