import Foundation
import Testing

struct BundledRuntimePathContractTests {
    @Test
    func scheduledRuntimeUsesBundledFirstPartyCode() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let targets = [
            "Payloads/Modules/systems.memory/bin/memory-capture",
            "Payloads/Modules/systems.memory/bin/memory-corpus-backup",
            "Payloads/Modules/systems.memory/bin/memory-health-weekly",
            "Payloads/Modules/systems.memory/bin/memory-transcript-distill",
            "Payloads/Modules/systems.memory/bin/semantic-index-retry",
            "Payloads/Modules/systems.memory/bin/semantic-corpus",
            "Payloads/Modules/systems.memory/bin/memory-retrieval-eval",
            "Payloads/Modules/systems.memory/bin/memory-project-init",
            "Payloads/Modules/systems.memory/bin/memory-semantic-build",
            "Payloads/Modules/systems.codex-improvement/bin/weekly-system-improvement",
            "Payloads/Modules/systems.codex-improvement/bin/weekly-system-improvement-health",
            "Payloads/Modules/systems.codex-improvement/bin/weekly_system_improvement.py",
            "Payloads/Modules/systems.repository-release/bin/app-repo-sync",
            "Payloads/Modules/systems.repository-release/bin/app-repo-bootstrap",
            "Payloads/Modules/systems.repository-release/bin/app-repo-lib.sh",
            "Payloads/Modules/systems.repository-release/bin/personal-repo-sync",
            "Payloads/Modules/systems.backup-audit/bin/backup-coverage-audit",
            "Payloads/Modules/connectors.local-read/bin/codex-read",
            "Payloads/Modules/mail.assistant/bin/apple-mail-draft-runner",
            "Payloads/Modules/mail.assistant/bin/mail-assistant-app-build",
        ]
        let forbidden = [
            "~/.memory/tools",
            "$HOME/.memory/tools",
            "${HOME}/.memory/tools",
            "~/.local/bin/",
            "$HOME/.local/bin/",
            "${HOME}/.local/bin/",
            "HOME / \".local\" / \"bin\"",
            "~/.memory/tests/run-all",
            "example-owner/private-source-archive",
        ]

        for relativePath in targets {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in forbidden {
                #expect(!source.contains(pattern), "forbidden external first-party path (pattern) in (relativePath)")
            }
        }

        let scheduler = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Switchboard/Services/AgentScheduler.swift"),
            encoding: .utf8
        )
        #expect(scheduler.contains("\"SWITCHBOARD_RESOURCES_DIR\": bundleURL.appending(path: \"Contents/Resources\").path"))

        let backupAudit = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Payloads/Modules/systems.backup-audit/bin/backup-coverage-audit"),
            encoding: .utf8
        )
        #expect(backupAudit.contains("../../systems.repository-release/bin/personal-repo-sync"))
        #expect(backupAudit.contains("AudioDisconnectGuard)"))
        #expect(backupAudit.contains("Personal-Repo)"))
    }
}
