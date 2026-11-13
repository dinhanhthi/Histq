// Key feature test for the command palette's ranking (task 8.5): an abbreviated query ranks the row it abbreviates
// first among the palette's real neighbours (the remote branch of the same name, the detached checkout, a merge of
// that branch).
import HistqCore
import Testing

struct FuzzyRankTests {
    @Test("\"chk dev\" ranks \"Checkout develop\" first, ahead of its remote branch and other rows naming develop")
    func abbreviationRanksCheckoutFirst() {
        let titles = [
            "Pull", "Fetch All", "Merge develop into main", "Rebase main onto develop",
            "Checkout This Commit (Detached)…", "Checkout feature", "Checkout origin/develop", "Checkout develop",
            "Cherry-pick Commit", "Switch to tab develop-notes",
        ]
        let rows = titles.map { [$0.lowercased()] }
        let ranked = FuzzyRank.rank(rows, query: "chk dev", limit: 50).map { titles[$0] }
        #expect(ranked.first == "Checkout develop")
        #expect(ranked.contains("Checkout origin/develop"))
        #expect(!ranked.contains("Checkout feature"))
        #expect(!ranked.contains("Merge develop into main"))
    }
}
