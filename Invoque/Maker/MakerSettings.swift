import Foundation

/// The Maker's provider configuration: base URL, model and provider mode in
/// `UserDefaults` (non-secret), the API key in Keychain (secret).
///
/// `ObservableObject` like `Preferences` so Settings edits update live.
/// Injectable `UserDefaults`/`Keychain` keep tests off the real stores.
final class MakerSettings: ObservableObject {

    static let shared = MakerSettings()

    /// Which wire protocol `LLMClient` speaks — type alias so the rest of
    /// the file (and call sites) can say `MakerSettings.Provider`.
    typealias Provider = LLMProvider

    // MARK: Defaults

    enum Default {
        static let provider = Provider.openAICompatible
        static let baseURL = "https://api.openai.com/v1"
        static let anthropicBaseURL = "https://api.anthropic.com"
        static let model = "gpt-4o-mini"
        static let anthropicModel = "claude-sonnet-4-5"
    }

    private enum Key {
        static let provider = "maker.provider"
        static let baseURL = "maker.baseURL"
        static let model = "maker.model"
    }

    /// Keychain account for the API key — the value itself never leaves
    /// the Keychain wrapper.
    private static let apiKeyAccount = "maker.llmAPIKey"

    private let defaults: UserDefaults
    private let keychain: Keychain

    // MARK: Stored settings

    @Published var provider: Provider {
        didSet {
            defaults.set(provider.rawValue, forKey: Key.provider)
            // Swap a stock base URL for the other provider's — a URL the
            // user customized is left alone. The model gets the same
            // treatment: a stock model id sent to the other provider is a
            // guaranteed 400 (e.g. "gpt-4o-mini" at api.anthropic.com).
            if provider == .anthropic && baseURL == Default.baseURL {
                baseURL = Default.anthropicBaseURL
                if model == Default.model { model = Default.anthropicModel }
            } else if provider == .openAICompatible
                        && baseURL == Default.anthropicBaseURL {
                baseURL = Default.baseURL
                if model == Default.anthropicModel { model = Default.model }
            }
        }
    }

    /// The API root the endpoint paths are appended to, e.g.
    /// `https://api.openai.com/v1` or `http://localhost:11434/v1`.
    @Published var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Key.baseURL) }
    }

    @Published var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }

    /// The API key. Read/write goes straight to Keychain; assigning "" or
    /// nil-equivalent clears it. Not `@Published` — nothing renders the key
    /// itself, only whether one is set — so the setter must still notify or
    /// `hasAPIKey`-driven UI goes stale.
    var apiKey: String {
        get { keychain.get(account: Self.apiKeyAccount) ?? "" }
        set {
            keychain.set(newValue, account: Self.apiKeyAccount)
            objectWillChange.send()
        }
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    // MARK: Init

    init(defaults: UserDefaults = .standard, keychain: Keychain = Keychain()) {
        self.defaults = defaults
        self.keychain = keychain
        provider = Provider(rawValue: defaults.string(forKey: Key.provider) ?? "")
            ?? Default.provider
        baseURL = defaults.string(forKey: Key.baseURL) ?? Default.baseURL
        model = defaults.string(forKey: Key.model) ?? Default.model
    }

    // MARK: Client

    /// A client snapshotting the current configuration. The Maker builds a
    /// fresh one per generation so Settings edits apply without a restart.
    func makeClient() -> LLMClient {
        LLMClient(configuration: LLMClient.Configuration(
            provider: provider,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey))
    }
}
