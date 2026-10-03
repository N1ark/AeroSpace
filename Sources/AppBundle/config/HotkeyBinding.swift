import AppKit
import Common
import Foundation
import HotKey

@MainActor private var hotkeys: [String: HotKey] = [:]

@MainActor func resetHotKeys() {
    // Explicitly unregister all hotkeys. We cannot always rely on destruction of the HotKey object to trigger
    // unregistration because we might be running inside a hotkey handler that is keeping its HotKey object alive.
    for (_, key) in hotkeys {
        key.isEnabled = false
    }
    hotkeys = [:]
    syncSidedHotkeys([])
}

extension HotKey {
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}

@MainActor var activeMode: String? = mainModeId
@MainActor func activateMode_nonCancellable(_ targetMode: String?) async {
    let targetBindings = targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    // Carbon hotkeys can't distinguish left and right modifiers. If at least one binding in the "modifiers + key" group
    // is sided (e.g. lalt-h), then the whole group (lalt-h, ralt-h, alt-h) is handled by the event tap
    let sidedGroups = Set(targetBindings.values.filter { !$0.sidedModifiers.isEmpty }.map(\.unsidedDescription))
    let (sidedBindings, carbonBindings) = targetBindings.partition { sidedGroups.contains($0.value.unsidedDescription) }
    for binding in carbonBindings.values where !hotkeys.keys.contains(binding.descriptionWithKeyCode) {
        hotkeys[binding.descriptionWithKeyCode] = HotKey(key: binding.keyCode, modifiers: binding.modifiers, keyDownHandler: {
            onHotkeyTriggered(binding)
        })
    }
    for (binding, key) in hotkeys {
        key.isEnabled = carbonBindings.keys.contains(binding)
    }
    syncSidedHotkeys(Array(sidedBindings.values))
    let oldMode = activeMode
    activeMode = targetMode
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        _ = await config.onModeChanged.run(.defaultEnv, .emptyStdin)
    }
}

@MainActor func onHotkeyTriggered(_ binding: HotkeyBinding) {
    Task.startUnstructured {
        if let activeMode {
            broadcastEvent(.bindingTriggered(
                mode: activeMode,
                binding: binding.descriptionWithKeyNotation,
            ))
            try await runLightSession(.hotkeyBinding, .checkServerIsEnabledOrDie()) { () throws in
                _ = await config.modes[activeMode]?.bindings[binding.descriptionWithKeyCode]?.commands
                    .run(.defaultEnv, .emptyStdin)
            }
        }
    }
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let sidedModifiers: SidedModifiers
    let keyCode: Key
    let commands: Shell<any Command>
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    init(
        _ modifiers: NSEvent.ModifierFlags,
        _ keyCode: Key,
        _ commands: Shell<any Command>,
        sidedModifiers: SidedModifiers = [],
        descriptionWithKeyNotation: String,
    ) {
        self.modifiers = modifiers
        self.sidedModifiers = sidedModifiers
        self.keyCode = keyCode
        self.commands = commands
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString(sidedModifiers) + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    var unsidedDescription: String {
        modifiers.isEmpty ? keyCode.toString() : modifiers.toString() + "-" + keyCode.toString()
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.sidedModifiers == rhs.sidedModifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.commands.strictEquals(rhs.commands)
    }
}

func parseBindings(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext, _ mapping: [String: Key]) -> [String: HotkeyBinding] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: HotkeyBinding] = [:]
    for (binding, rawCommand): (String, OrderedJson) in rawTable {
        let backtrace = backtrace + .key(binding)
        let binding = parseBinding(binding, backtrace, mapping)
            .map { modifiers, sidedModifiers, key -> HotkeyBinding in
                let commands = parseShellOfCommandsForConfig(rawCommand, backtrace, &c)
                return HotkeyBinding(modifiers, key, commands, sidedModifiers: sidedModifiers, descriptionWithKeyNotation: binding)
            }
            .getOrNil(appendErrorTo: &c.errors)
        if let binding {
            if result.keys.contains(binding.descriptionWithKeyCode) {
                c.errors.append(.init(backtrace, "'\(binding.descriptionWithKeyCode)' Binding redeclaration"))
            }
            result[binding.descriptionWithKeyCode] = binding
        }
    }
    return result
}

func parseBinding(_ raw: String, _ backtrace: ConfigBacktrace, _ mapping: [String: Key]) -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, SidedModifiers, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, SidedModifiers)> = rawKeys.dropLast()
        .mapAllOrFailure {
            modifiersMap[String($0)].toResult(.init(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { modifiers in
            (NSEvent.ModifierFlags(modifiers.map(\.0)), SidedModifiers(modifiers.map(\.1)))
        }
    let key: ResOrConfigParseDiagnostic<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .toResult(.init(backtrace, "Can't parse the key in '\(raw)' binding"))
    return modifiers.flatMap { modifiers, sidedModifiers -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, SidedModifiers, Key)> in
        key.flatMap { key -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, SidedModifiers, Key)> in
            .success((modifiers, sidedModifiers, key))
        }
    }
}
