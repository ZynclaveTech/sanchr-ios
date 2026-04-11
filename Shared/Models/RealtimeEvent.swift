import Foundation
import SanchrShared

/// Internal representation of the app-wide realtime message stream.
enum RealtimeEvent: Sendable {
    case message(Message)
    case typing(Sanchr_Messaging_TypingIndicator)
    case receipt(Sanchr_Messaging_ReceiptUpdate)
    case presence(Sanchr_Messaging_PresenceUpdate)
    case preKeyCountLow(Sanchr_Messaging_PreKeyCountLow)
    case callOffer(Sanchr_Messaging_CallOfferEvent)
    case callLifecycle(Sanchr_Messaging_CallLifecycleEvent)
    case reaction(Sanchr_Messaging_Reaction)
    case sealedMessage(Sanchr_Messaging_SealedInboundMessage)
}
