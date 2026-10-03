//
//  IgnoreSettingsView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  全局忽略规则设置面板（开发者预设、自定义规则、内置规则查看，支持双语国际化）
//

import SwiftUI
import CloudDriveCore

struct IgnoreSettingsView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    
    @State private var globalPatterns: [String] = []
    @State private var newPattern: String = ""
    @State private var enableBuiltinRules: Bool = true
    @State private var showingPresetSheet: Bool = false
    @State private var showSavedToast: Bool = false
    
    var body: some View {
        Form {
            // MARK: - 1. 系统内置规则
            Section(L("ignore_section_builtin")) {
                Toggle(L("ignore_toggle_builtin"), isOn: $enableBuiltinRules)
                    .onChange(of: enableBuiltinRules) { newValue in
                        IgnoreRuleEngine.shared.enableBuiltinRules = newValue
                        saveSettings()
                    }
                
                DisclosureGroup(L("ignore_builtin_list_title", IgnoreRuleEngine.builtinRules.count)) {
                    ForEach(IgnoreRuleEngine.builtinRules) { rule in
                        HStack {
                            Text(rule.pattern)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                            Spacer()
                            Text(rule.comment ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            
            // MARK: - 2. 软件级别全局规则 (对所有加密库生效)
            Section(L("ignore_section_global")) {
                Text(L("ignore_global_desc"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                if globalPatterns.isEmpty {
                    Text(L("ignore_empty_custom"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(globalPatterns, id: \.self) { pattern in
                                    HStack {
                                        Text(pattern)
                                            .font(.system(.body, design: .monospaced))
                                        Spacer()
                                        Button(role: .destructive) {
                                            removePattern(pattern)
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red.opacity(0.8))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    Divider()
                                }
                            }
                        }
                        .frame(maxHeight: 130)
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
                    )
                }
                
                HStack {
                    TextField(L("ignore_placeholder"), text: $newPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            addPattern()
                        }
                    
                    Button(L("ignore_btn_add")) {
                        addPattern()
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            
            // MARK: - 3. 开发者常用预设
            Section(L("ignore_section_preset")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("ignore_preset_title"))
                            .font(.body)
                        Text(L("ignore_preset_desc"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(L("ignore_btn_select_preset")) {
                        showingPresetSheet = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear {
            loadSettings()
        }
        .sheet(isPresented: $showingPresetSheet) {
            DeveloperPresetSheet(currentPatterns: $globalPatterns, onApplied: {
                saveSettings()
            })
        }
    }
    
    // MARK: - 规则增删与持久化
    
    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !globalPatterns.contains(trimmed) {
            globalPatterns.append(trimmed)
            saveSettings()
        }
        newPattern = ""
    }
    
    private func removePattern(_ pattern: String) {
        globalPatterns.removeAll { $0 == pattern }
        saveSettings()
    }
    
    private func loadSettings() {
        let settingsFile = CloudDrivePaths.sharedDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.globalPatterns = IgnoreRuleEngine.shared.getGlobalPatterns()
            self.enableBuiltinRules = IgnoreRuleEngine.shared.enableBuiltinRules
            return
        }
        
        if let patterns = json["globalIgnorePatterns"] as? [String] {
            self.globalPatterns = patterns
        } else {
            self.globalPatterns = IgnoreRuleEngine.shared.getGlobalPatterns()
        }
        
        if let builtin = json["enableBuiltinIgnoreRules"] as? Bool {
            self.enableBuiltinRules = builtin
            IgnoreRuleEngine.shared.enableBuiltinRules = builtin
        }
    }
    
    private func saveSettings() {
        IgnoreRuleEngine.shared.setGlobalPatterns(globalPatterns)
        IgnoreRuleEngine.shared.enableBuiltinRules = enableBuiltinRules
        
        let settingsFile = CloudDrivePaths.sharedDirectory.appendingPathComponent("settings.json")
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        
        json["globalIgnorePatterns"] = globalPatterns
        json["enableBuiltinIgnoreRules"] = enableBuiltinRules
        
        if let outputData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? outputData.write(to: settingsFile, options: .atomic)
        }
    }
}

// MARK: - 开发者预设选择面板

struct DeveloperPresetSheet: View {
    @Binding var currentPatterns: [String]
    var onApplied: () -> Void
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var localization = LocalizationManager.shared
    
    @State private var selectedCategories: Set<String> = []
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("preset_sheet_title"))
                    .font(.headline)
                Spacer()
                Button(L("done")) {
                    applySelected()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            
            Divider()
            
            List {
                ForEach(Array(IgnoreRuleEngine.developerPresets.keys.sorted()), id: \.self) { category in
                    Section(header: HStack {
                        Toggle(category, isOn: Binding(
                            get: { selectedCategories.contains(category) },
                            set: { isSelected in
                                if isSelected {
                                    selectedCategories.insert(category)
                                } else {
                                    selectedCategories.remove(category)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    }) {
                        ForEach(IgnoreRuleEngine.developerPresets[category] ?? [], id: \.self) { rule in
                            HStack {
                                Text(rule)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Spacer()
                                if currentPatterns.contains(rule) {
                                    Text(L("preset_sheet_already_added"))
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            
            Divider()
            
            HStack {
                Button(L("preset_select_all")) {
                    selectedCategories = Set(IgnoreRuleEngine.developerPresets.keys)
                }
                Button(L("preset_deselect_all")) {
                    selectedCategories.removeAll()
                }
                Spacer()
                Button(L("cancel")) {
                    dismiss()
                }
                Button(L("preset_import_selected")) {
                    applySelected()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCategories.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 480)
    }
    
    private func applySelected() {
        for category in selectedCategories {
            if let rules = IgnoreRuleEngine.developerPresets[category] {
                for rule in rules {
                    if !currentPatterns.contains(rule) {
                        currentPatterns.append(rule)
                    }
                }
            }
        }
        onApplied()
    }
}
