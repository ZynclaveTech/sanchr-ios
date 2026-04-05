import Foundation

/// Internal representation of the app-wide realtime message stream.
enum RealtimeEvent: Sendable {
    case message(Message)
    case typing(Vync_Messaging_TypingIndicator)
    case receipt(Vync_Messaging_ReceiptUpdate)
    case presence(Vync_Messaging_PresenceUpdate)
    case preKeyCountLow(Vync_Messaging_PreKeyCountLow)
    case callOffer(Vync_Messaging_CallOfferEvent)
    case callLifecycle(Vync_Messaging_CallLifecycleEvent)
    case reaction(Vync_Messaging_Reaction)
}
