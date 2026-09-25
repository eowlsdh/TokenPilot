import Foundation

extension UserDefaults {
    /// Stores `data` only when it differs from what is already under `key`.
    ///
    /// Writing identical bytes is not free: the preferences file is rewritten whole. Measured on a
    /// real install, the usage-history blob — 786 KB — was rewritten every ninety seconds to store
    /// exactly the bytes already there, because the refresh saves on every pass including the one
    /// where nothing new arrived, which is every pass for anyone whose enabled providers report no
    /// token events.
    ///
    /// The encode has already happened by the time this is called, so the comparison is the only
    /// added cost, and it buys away the write.
    func setIfChanged(_ data: Data, forKey key: String) {
        guard data != self.data(forKey: key) else { return }
        set(data, forKey: key)
    }
}
