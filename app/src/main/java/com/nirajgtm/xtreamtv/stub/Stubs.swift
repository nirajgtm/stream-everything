import Foundation
// Minimal stand-ins for app types the data layer references.
@MainActor final class AppState { var live: [Entry] = []; var movies: [Entry] = []; var series: [Entry] = []; var adultFilter = true }
final class XtreamClient { let server = "", user = "", pass = "" }
enum Credentials { static let tmdbKey = ""; static let watchmodeKey = "" }
