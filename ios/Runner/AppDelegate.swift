import Flutter
import UIKit
import AppIntents
import CoreSpotlight
import intelligence

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Dart republishes the entity store whenever the cooking plan changes
    // (SiriService.syncPlannedRecipes). Telling the App Intents framework to
    // re-read its shortcut parameters is what makes a newly planned meal show
    // up in Siri's suggestions without a reinstall.
    IntelligencePlugin.storage.attachListener {
      PlannerShortcuts.updateAppShortcutParameters()
    }
    if #available(iOS 18.0, *) {
      // Also index the planned meals in Spotlight, so they're findable from
      // search rather than only through Siri.
      IntelligencePlugin.spotlightCore.attachEntityMapper { item in
        PlannedMealEntity(id: item.id, representation: item.representation)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// =============================================================================
// App Intents
// =============================================================================
//
// Apple discovers AppIntents by scanning the *compiled* main app target, so
// these types have to be concrete Swift declared at build time — they can't be
// registered from Dart. They therefore stay deliberately dumb: each one pushes
// a payload string to the Flutter side (see lib/features/siri/siri_service.dart,
// which owns the matching prefixes) and lets Dart do the actual work against
// Firestore.
//
// The one exception is NextPlannedMealsIntent, which answers out of the entity
// store the plugin persists to disk. That store is readable with no Flutter
// engine running, so "what are we cooking?" is answered without launching the
// app — the difference between a spoken reply and a cold start.
//
// These live in AppDelegate.swift rather than their own file only because a new
// file has to be added to the Xcode target by hand; splitting them out is safe
// to do from Xcode whenever you like.

/// Payload prefixes. Must stay in sync with the `k*Payload` constants in
/// lib/features/siri/siri_service.dart.
enum SiriPayload {
  static let shopping = "shopping:"
  static let plan = "plan:"
  static let openRecipes = "open:recipes"
  static let openShopping = "open:shopping"
}

// MARK: - Add to shopping list

struct AddShoppingItemIntent: AppIntent {
  static var title: LocalizedStringResource = "Add to shopping list"
  static var description = IntentDescription(
    "Puts an item on your group's shopping list. An amount and a unit are picked up too, e.g. \"2 litres of milk\"."
  )

  // The write happens in Dart against Firestore, which needs the Flutter
  // engine, so this one does open the app. The snackbar shown on arrival is
  // the user-visible confirmation.
  static var openAppWhenRun: Bool = true
  static var isDiscoverable: Bool = true

  @Parameter(
    title: "Item",
    description: "What to add, optionally with an amount.",
    requestValueDialog: "What should I add to the list?"
  )
  var item: String

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$item) to the shopping list")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .result() }
    IntelligencePlugin.notifier.push(SiriPayload.shopping + text)
    return .result()
  }
}

// MARK: - What's planned

struct NextPlannedMealsIntent: AppIntent {
  static var title: LocalizedStringResource = "Next planned meals"
  static var description = IntentDescription(
    "Reads out the meals planned for the coming days."
  )

  // Answered entirely from the persisted entity store — no app launch.
  static var openAppWhenRun: Bool = false
  static var isDiscoverable: Bool = true

  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let items = IntelligencePlugin.storage.get()
    guard !items.isEmpty else {
      // Both replies resolve against Localizable.xcstrings, so they come back
      // in Siri's language rather than the app's — the user just spoke, and
      // being answered in the language they spoke is what they expect. The meal
      // names inside are whatever the group stored them as, untranslated.
      let empty = String(localized: "Nothing is planned for the next few days.")
      return .result(value: empty, dialog: IntentDialog(stringLiteral: empty))
    }

    // Dart publishes these already ordered by date and capped, each formatted
    // as "Lasagne · tomorrow" (the day word localised by SiriService._dayLabel).
    // Read out the first few; the rest are in the app.
    let spoken = items.prefix(5)
      .map { $0.representation }
      .joined(separator: ", ")
    let sentence = String(format: String(localized: "Coming up: %@."), spoken)
    return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
  }
}

// MARK: - Planned meal as an entity

/// One upcoming meal, mirrored from Firestore by Dart. `id` is already the full
/// routing payload (`plan:<cookingPlanDocId>`), so an intent can push it
/// straight across without reassembling anything.
struct PlannedMealEntity: AppEntity {
  static var defaultQuery = PlannedMealQuery()
  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Planned meal")

  let id: String
  let representation: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(stringLiteral: representation)
  }
}

@available(iOS 18.0, *)
extension PlannedMealEntity: IndexedEntity {
  var attributeSet: CSSearchableItemAttributeSet {
    let attributes = CSSearchableItemAttributeSet()
    attributes.displayName = representation
    return attributes
  }
}

struct PlannedMealQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [PlannedMealEntity] {
    IntelligencePlugin.storage.get(for: identifiers).map {
      PlannedMealEntity(id: $0.id, representation: $0.representation)
    }
  }

  func suggestedEntities() async throws -> [PlannedMealEntity] {
    try await allEntities()
  }
}

extension PlannedMealQuery: EnumerableEntityQuery {
  func allEntities() async throws -> [PlannedMealEntity] {
    IntelligencePlugin.storage.get().map {
      PlannedMealEntity(id: $0.id, representation: $0.representation)
    }
  }
}

struct OpenPlannedMealIntent: AppIntent {
  static var title: LocalizedStringResource = "Open a planned meal"
  static var description = IntentDescription("Opens the recipe for a planned meal.")
  static var openAppWhenRun: Bool = true
  static var isDiscoverable: Bool = true

  @Parameter(title: "Meal")
  var meal: PlannedMealEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$meal)")
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    IntelligencePlugin.notifier.push(meal.id)
    return .result()
  }
}

// MARK: - Plain navigation

struct OpenShoppingListIntent: AppIntent {
  static var title: LocalizedStringResource = "Open shopping list"
  static var description = IntentDescription("Shows your group's shopping list.")
  static var openAppWhenRun: Bool = true
  static var isDiscoverable: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    IntelligencePlugin.notifier.push(SiriPayload.openShopping)
    return .result()
  }
}

struct OpenMealPlanIntent: AppIntent {
  static var title: LocalizedStringResource = "Open meal plan"
  static var description = IntentDescription("Shows your recipes and the days ahead.")
  static var openAppWhenRun: Bool = true
  static var isDiscoverable: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    IntelligencePlugin.notifier.push(SiriPayload.openRecipes)
    return .result()
  }
}

// MARK: - Spoken phrases

/// Phrases are compiled into the binary and cannot be built at runtime, so this
/// list is the complete set of things Siri will recognise.
///
/// **Every phrase must contain `\(.applicationName)`.** Apple enforces this so
/// app phrases can't collide with system commands; a phrase without it compiles
/// fine and then silently never matches.
///
/// That token expands to the display name *and* to each `INAlternativeAppNames`
/// entry in Info.plist — currently just "Shopping List". So
/// `"Add something to my \(.applicationName)"` is what makes the natural
/// "Hey Siri, add something to my shopping list" work without breaking the rule.
///
/// The catch is that synonyms are app-wide, not per-intent: every phrase below
/// is expanded against every name, which is why the list is kept to one. The
/// phrases still carry their own domain word ("cooking", "shopping list",
/// "meal plan") wherever the "Shopping List" expansion would otherwise send a
/// request to the wrong tab. Adding a second synonym means re-checking every
/// phrase in this file against it.
///
/// Also deliberately absent: `AddShoppingItemIntent`'s `item` parameter is not
/// interpolated into any phrase. Apple only allows AppEnum or AppEntity
/// parameters inside App Shortcut phrases — a free-form String can't be part of
/// the spoken trigger. So the phrase makes Siri ask "What should I add to the
/// list?" (the parameter's requestValueDialog) and take the answer as free
/// text, which is the behaviour we want regardless.
///
/// `PlannedMealEntity` *is* an entity, so "open the lasagne" resolves directly.
///
/// The German and Spanish versions of every phrase below live in
/// AppShortcuts.xcstrings, keyed by the English string exactly as written here
/// — edit one and the other must follow, or the translation silently falls back
/// to English. That catalog is also what forced the iOS 17 deployment target:
/// String Catalogs are 17+, and the only alternative is three
/// `<lang>.lproj/AppShortcuts.strings` files.
struct PlannerShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    // "…my \(.applicationName)" is the whole point of the synonym: with
    // "Shopping List" registered, these read as "add something to my shopping
    // list" / "add to my shopping list" / "put something on my shopping list".
    AppShortcut(
      intent: AddShoppingItemIntent(),
      phrases: [
        "Add something to my \(.applicationName)",
        "Add to my \(.applicationName)",
        "Put something on my \(.applicationName)"
      ],
      shortTitle: "Add to list",
      systemImageName: "cart.badge.plus"
    )
    // Each of these keeps a cooking word of its own, so the "Shopping List"
    // expansion is merely unnatural rather than wrong — nobody says "what are
    // we cooking in shopping list", but if they did, answering with meals is
    // still the right answer.
    AppShortcut(
      intent: NextPlannedMealsIntent(),
      phrases: [
        "What's for dinner in \(.applicationName)",
        "What are we cooking in \(.applicationName)",
        "What's planned in \(.applicationName)",
        "Next meals from \(.applicationName)"
      ],
      shortTitle: "Next meals",
      systemImageName: "fork.knife"
    )
    AppShortcut(
      intent: OpenPlannedMealIntent(),
      phrases: [
        "Open \(\.$meal) in \(.applicationName)",
        "Show \(\.$meal) with \(.applicationName)"
      ],
      shortTitle: "Open meal",
      systemImageName: "book"
    )
    // The two "open" intents name their destination explicitly rather than
    // leaning on the synonym. "Open my \(.applicationName)" would have read
    // nicely for one name and sent the user to the wrong tab for the other.
    AppShortcut(
      intent: OpenShoppingListIntent(),
      phrases: [
        "Open my shopping list in \(.applicationName)",
        "Show the shopping list in \(.applicationName)"
      ],
      shortTitle: "Shopping list",
      systemImageName: "cart"
    )
    AppShortcut(
      intent: OpenMealPlanIntent(),
      phrases: [
        "Open my meal plan in \(.applicationName)",
        "Show my recipes in \(.applicationName)"
      ],
      shortTitle: "Meal plan",
      systemImageName: "calendar"
    )
  }
}
