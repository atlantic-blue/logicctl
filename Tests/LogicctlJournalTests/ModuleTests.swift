import LogicctlJournal
import Testing

/// The journal is built on the core, so a session can be written from what a command read.
@Test func theJournalIsBuiltOnTheCore() {
  #expect(LogicctlJournal.coreModuleName == "LogicctlCore")
}
