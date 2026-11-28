/// A quota check can require account changes, or fail while the account is still usable.
public enum QuotaAccountRepair: Equatable, Sendable {
  case reconnect
  case finishSetup

  public init?(needsSetup: Bool, failureKind: QuotaErrorKind?) {
    if needsSetup || failureKind == .notConfigured {
      self = .finishSetup
    } else if failureKind == .auth {
      self = .reconnect
    } else {
      return nil
    }
  }
}
