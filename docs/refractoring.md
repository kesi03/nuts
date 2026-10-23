# NUTS Navigation Refactor - Phase 1 Specification

## Objective

Implement a new navigation architecture that:

- Removes page-to-page navigation using category buttons.
- Introduces Bank A / Bank B using the User button.
- Retains the existing YAML page model.
- Retains pager definitions in YAML.
- Keeps Categories and Bank independent.
- Minimises changes to existing generated YAML and Lua logic.
- Creates a foundation for future Category + Bank interactions.

---

# Scope

This phase only delivers:

```text
Categories
Bank
Page
```

as separate navigation dimensions.

This phase does NOT implement:

```text
Mixer Bank A = Channel
Mixer Bank B = Master

Instrument Bank A = Basic
Instrument Bank B = Advanced

Effect Bank A = Main
Effect Bank B = Deep
```

These concepts are deferred to a later phase.

---

# Controller Layout

```text
Learn | View | Page- | Page+ | User | Fx | Instr | Mixer
```

---

# Button Responsibilities

## Categories

| Button | Category |
|----------|----------|
| Learn | Player |
| View | Document |
| Fx | Effect |
| Instr | Instrument |
| Mixer | Mixer |

Pressing a category button:

```text
Changes Category
Resets Page to 1
Keeps Current Bank
```

Example:

Before:

```text
Document
Bank B
Page 3
```

User presses:

```text
Instr
```

Result:

```text
Instrument
Bank B
Page 1
```

---

## Page Navigation

```text
Page-
Page+
```

These are the only controls that change pages.

Pages remain:

```text
1
2
3
4
```

within the active Category and Bank.

---

## Bank Selection

The User button becomes:

```text
Bank Toggle
```

State:

```text
Bank A
Bank B
```

Recommended behaviour:

```text
LED Off = Bank A
LED On  = Bank B
```

Pressing User:

```text
A → B
B → A
```

---

# Navigation State

C# maintains:

```csharp
public class NavigationState
{
    public string Category;
    public string Bank;
    public int Page;
}
```

Example:

```text
Category = Document
Bank     = B
Page     = 2
```

This becomes the authoritative navigation state.

---

# Excel Specification

## Sheet 1 (Index)

Columns:

```text
Section
Device
Manufacturer
Model
Parameters
Category
Button
```

Valid Category values:

```text
Instrument
Effect
Player
Mixer
Document
```

Valid Button values:

```text
Instr
Fx
Learn
Mixer
View
```

The Excel file becomes the single source of truth for device classification.

---

# YAML Specification

## Keep Existing Pager Definition

Every page retains:

```yaml
pager:
  - {
      name: pageMinus,
      key: PageMinusCc,
      direction: "-",
      min: 0,
      max: 1,
      input_type: Toggle,
    }

  - {
      name: pagePlus,
      key: PagePlusCc,
      direction: "+",
      min: 0,
      max: 1,
      input_type: Toggle,
    }
```

No behavioural changes.

---

## Replace Navigation With Categories

Current approach:

```yaml
navigation:
  - Transport
  - Navigation
  - Loop
  - Track
```

New approach:

```yaml
categories:
  - {
      name: Player,
      category: Player,
      key: LearnCc,
      min: 0,
      max: 1,
      input_type: Toggle,
    }

  - {
      name: Document,
      category: Document,
      key: ViewCc,
      min: 0,
      max: 1,
      input_type: Toggle,
    }

  - {
      name: Effect,
      category: Effect,
      key: FxCc,
      min: 0,
      max: 1,
      input_type: Toggle,
    }

  - {
      name: Instrument,
      category: Instrument,
      key: InstrCc,
      min: 0,
      max: 1,
      input_type: Toggle,
    }

  - {
      name: Mixer,
      category: Mixer,
      key: MixCc,
      min: 0,
      max: 1,
      input_type: Toggle,
    }
```

These definitions become common metadata across all generated YAML documents.

---

## Add Bank Definition

```yaml
bank:
  - {
      name: Bank,
      key: UserCc,
      values: [A, B],
      input_type: Toggle,
    }
```

This defines User as a bank selector.

---

# Page Model

Pages remain unchanged.

Example:

```text
Document
├─ Transport
├─ Navigation
├─ Loop
└─ Track
```

No changes are required to existing page definitions.

---

# Runtime Resolution

Current lookup:

```text
Document
Page 1
```

New lookup:

```text
Document
Bank A
Page 1
```

Resolved internally as:

```text
Document:A:1
```

Examples:

```text
Document:A:2

Document:B:1

Instrument:A:3

Effect:B:4

Mixer:A:2
```

---

# Generator Changes

Generator keys must become:

```text
Category
+
Bank
+
Page
```

Example:

```text
Document:A:1
Document:A:2
Document:A:3
Document:A:4

Document:B:1
Document:B:2
Document:B:3
Document:B:4
```

The same pattern applies to:

```text
Instrument
Effect
Player
Mixer
```

---

# MIDI Layer

The C# driver remains the authoritative source of navigation state.

Suggested implementation:

```text
Bank A = MIDI Channel 1

Bank B = MIDI Channel 10
```

Alternative:

```text
Dedicated Bank CC message
```

The transport mechanism can be decided during implementation.

---

# Lua Changes

Lua should no longer infer navigation state from device focus.

Instead maintain:

```lua
currentCategory
currentBank
currentPage
```

Example:

```lua
currentCategory = "Instrument"
currentBank = "B"
currentPage = 2
```

---

# Acceptance Criteria

## Categories

```text
Learn selects Player
View selects Document
Fx selects Effect
Instr selects Instrument
Mixer selects Mixer
```

## Bank

```text
User toggles Bank A / Bank B
```

## Pages

```text
Only Page- and Page+ change pages
```

## State Model

```text
Category + Bank + Page
```

fully defines the current layout.

## Compatibility

```text
Existing page structure remains unchanged.
Existing controls remain unchanged.
Existing pager definitions remain unchanged.
```

---

# Future Phase (Out Of Scope)

Potential future enhancements:

```text
Mixer
  Bank A = Current Channel
  Bank B = Master Section

Instrument
  Bank A = Performance
  Bank B = Advanced

Effect
  Bank A = Main
  Bank B = Deep Edit
```

These behaviours are explicitly excluded from Phase 1 and must not be hardcoded into the architecture.