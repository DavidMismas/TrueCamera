import re

with open('TrueCamera/ContentView.swift', 'r') as f:
    lines = f.readlines()

# find settingsSheet
start_settings = -1
end_settings = -1
for i, line in enumerate(lines):
    if "private var settingsSheet: some View {" in line:
        start_settings = i
    if start_settings != -1 and i > start_settings and line.startswith("    }"):
        end_settings = i
        break

settings_content = lines[start_settings:end_settings+1]

# find selectedUserPreset to shortPresetTitle
start_effects = -1
end_effects = -1
for i, line in enumerate(lines):
    if "private var selectedUserPreset: PhotoEffectPreset? {" in line:
        start_effects = i
    if start_effects != -1 and i > start_effects and "private func shortPresetTitle" in line:
        # scan for end of shortPresetTitle
        for j in range(i, len(lines)):
            if lines[j].startswith("    }"):
                end_effects = j
                break
        if end_effects != -1:
            break

effects_content = lines[start_effects:end_effects+1]

# write settings
with open('TrueCamera/Views/ContentView+Settings.swift', 'w') as f:
    f.write('import SwiftUI\nimport Photos\n\nextension ContentView {\n')
    for line in settings_content:
        # replace private var with var
        line = line.replace('private var settingsSheet: some View', 'var settingsSheet: some View')
        f.write(line)
    f.write('}\n')

# write effects
with open('TrueCamera/Views/ContentView+Effects.swift', 'w') as f:
    f.write('import SwiftUI\nimport Photos\n\nextension ContentView {\n')
    for line in effects_content:
        line = line.replace('private var effectsSheet: some View', 'var effectsSheet: some View')
        line = line.replace('private var selectedUserPreset:', 'var selectedUserPreset:')
        line = line.replace('private var selectedPresetHasUnsavedChanges:', 'var selectedPresetHasUnsavedChanges:')
        line = line.replace('private func ', 'func ')
        line = line.replace('private var referencePreview:', 'var referencePreview:')
        f.write(line)
    f.write('}\n')
