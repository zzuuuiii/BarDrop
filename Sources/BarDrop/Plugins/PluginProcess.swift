import Foundation
import Darwin

/// Startet ein Programm für ein Plugin, ohne Shell und mit den Argumenten genau so, wie das
/// Skript sie übergibt.
///
/// `Process` (NSTask) wandelt jedes Argument in die Schreibweise des Dateisystems um und
/// zerlegt dabei Umlaute in Buchstabe und Punkte („ä“ wurde zu „a“ plus Trema). Ein
/// Programm bekam so nicht wörtlich, was das Plugin übergeben hatte (Schnittstellen-Test
/// „Argumente ohne Shell“). Hier gehen die Argumente unverändert als UTF-8 hinaus.
///
/// Dieselben Eigenschaften, die der Plugin-Lauf von `Process` brauchte: Programm, Argumente,
/// Umgebung, Arbeitsordner, Ausgabe über zwei Pipes, leere Eingabe, Kennung, läuft noch,
/// Rückgabewert (bei einem Signal dessen Nummer, wie bei `Process`) und ein Abschluss.
final class PluginProcess {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let directory: URL
    let standardOutput: Pipe
    let standardError: Pipe

    /// Kommt einmal, sobald das Programm beendet ist (auf einer Hintergrund-Warteschlange)
    var terminationHandler: ((PluginProcess) -> Void)?

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var running = false
    private var finished = false
    private var status: Int32 = 0

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         standardOutput: Pipe, standardError: Pipe) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    var processIdentifier: pid_t { lock.lock(); defer { lock.unlock() }; return pid }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var terminationStatus: Int32 { lock.lock(); defer { lock.unlock() }; return status }

    struct LaunchError: LocalizedError {
        let code: Int32
        var errorDescription: String? { String(cString: strerror(code)) }
    }

    func run() throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let outWrite = standardOutput.fileHandleForWriting.fileDescriptor
        let errWrite = standardError.fileHandleForWriting.fileDescriptor
        // Eingabe leer, Ausgabe in die beiden Pipes; alles andere bleibt zu (CLOEXEC_DEFAULT)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outWrite, 1)
        posix_spawn_file_actions_adddup2(&actions, errWrite, 2)
        _ = directory.withUnsafeFileSystemRepresentation { path in
            posix_spawn_file_actions_addchdir_np(&actions, path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Signale wie bei einem frisch gestarteten Programm, keine geerbten Dateien
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // Argumente wörtlich als UTF-8 (nicht in Dateisystem-Schreibweise)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let result = executable.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return ENOENT }
            return argv.withUnsafeBufferPointer { a in
                envp.withUnsafeBufferPointer { e in
                    posix_spawn(&child, path, &actions, &attributes, a.baseAddress, e.baseAddress)
                }
            }
        }
        guard result == 0 else { throw LaunchError(code: result) }

        // Die schreibenden Enden gehören jetzt dem Programm: hier schließen, sonst endet die
        // Ausgabe nie (readDataToEndOfFile wartete ewig)
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()

        lock.lock()
        pid = child
        running = true
        lock.unlock()

        // Ein eigener Faden wartet auf das Ende. (Eine Beobachtung über Dispatch konnte das
        // Ende verpassen, wenn das Programm schon fertig war, bevor sie stand.) Er hält das
        // Objekt, bis das Programm beendet ist.
        let waiter = Thread { [self] in
            var raw: Int32 = 0
            var got: pid_t
            repeat { got = waitpid(child, &raw, 0) } while got == -1 && errno == EINTR
            // Ohne Ergebnis von waitpid nicht „erfolgreich“ melden (0), sondern wie Rückgabewert 1
            finish(raw: got == child ? raw : 1 << 8)
        }
        waiter.name = "BarDrop.plugin.wait"
        waiter.qualityOfService = .userInitiated
        waiter.start()
    }

    /// Rückgabewert übernehmen und den Abschluss genau einmal melden
    private func finish(raw: Int32) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        running = false
        // Wie Process: normal beendet → Rückgabewert, durch ein Signal → dessen Nummer
        let signaled = (raw & 0x7f) != 0 && (raw & 0x7f) != 0x7f
        status = signaled ? (raw & 0x7f) : ((raw >> 8) & 0xff)
        let handler = terminationHandler
        terminationHandler = nil
        lock.unlock()
        handler?(self)
    }
}
