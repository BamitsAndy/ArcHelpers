# ArcGIS Pro Layout Helper Functions - Plan

## Overview
Helper functions for ArcGIS Pro 3.5 to automate layout elements including category tables and activity state indicators.

## 1. Configuration File (`layout_config.json`)
External JSON file for colours with hierarchical search:
- **Search order**: Explicit path → Project folder → Tool folder → Built-in defaults
- **Category colours**: 8 RGB tuples for categories `['a','b','c','d','e','f','g','h']`
- **Activity thresholds**: Configurable ranges with colors for Low/Med/High states
- **Table styling**: Alternating row colors

```json
{
  "category_order": ["a", "b", "c", "d", "e", "f", "g", "h"],
  "category_colors": {
    "a": [255, 0, 0],
    "b": [0, 255, 0],
    "c": [0, 0, 255],
    "d": [255, 255, 0],
    "e": [255, 0, 255],
    "f": [0, 255, 255],
    "g": [128, 128, 128],
    "h": [255, 128, 0]
  },
  "activity_thresholds": {
    "Low": {"min": 0, "max": 9, "color": [0, 0, 255]},
    "Med": {"min": 10, "max": 20, "color": [0, 128, 0]},
    "High": {"min": 21, "max": null, "color": [255, 140, 0]}
  },
  "table_styling": {
    "row_colors": {
      "odd": [64, 64, 64],
      "even": [80, 80, 80]
    }
  }
}
```

- **`category_order`**: Explicit ordered list defining display order (not alphabetical)
  - Allows custom ordering e.g. `["d", "a", "h", "b", ...]`
  - Used by both static and dynamic table generators
- **`activity_thresholds`**: Explicit ranges for activity states
  - `min`/`max` define inclusive bounds (null = no limit)
  - Each state has its own color definition
- **`table_styling`**: Alternating row background colors
  - Odd rows: Dark grey (`rgb(64,64,64)`)
  - Even rows: Lighter grey (`rgb(80,80,80)`)

## 2. Core Data Helper

### `get_category_track_counts(feature_layer, category_field='class', track_id_field='trackId', output_table=None)` → `dict`
- Uses `arcpy.analysis.Statistics` with CASE_FIELD for efficient counting
- Returns `{category: count_of_unique_trackIds}`
- Optionally persists to file geodatabase via `output_table` parameter
- **Raises**: `ValueError` if layer/fields don't exist; descriptive errors for toolbox integration
- Used by both table generators and state indicator

### `get_unique_category_order(config_path=None)` → `list`
- Returns explicit category order from config (not alphabetical)
- Follows config hierarchy: explicit path → project → tool → defaults
- Allows custom ordering beyond a-h

## 3. Table HTML Generators

### `build_static_category_table(feature_layer, config_path=None)` → `str` (HTML)
- Always displays all 8 categories (a-h) regardless of data presence
- Each row: colour box + category identifier + unique track count
- Uses **inline CSS styles** for ArcGIS Pro compatibility
- Alternating row background: Dark Grey / Lighter Grey
- Uses fixed column order from config

### `build_dynamic_category_table(feature_layer, config_path=None)` → `str` (HTML)
- Only displays categories that exist in the dataset
- Maintains **explicit fixed order** from config (not alphabetical)
- Same styling approach as static table
- Useful for showing only relevant categories

### HTML Table Structure
```html
<table style="border-collapse: collapse;">
  <tr style="background-color: rgb(64, 64, 64);">
    <td style="background-color: rgb(255, 0, 0); width: 20px;"></td>
    <td style="padding: 4px;">a</td>
    <td style="padding: 4px;">5</td>
  </tr>
  <tr style="background-color: rgb(80, 80, 80);">
    <td style="background-color: rgb(0, 255, 0); width: 20px;"></td>
    <td style="padding: 4px;">b</td>
    <td style="padding: 4px;">3</td>
  </tr>
</table>
```

## 4. State Indicator

### `get_activity_state(feature_layer, categories=['a','b','c','d'], config_path=None)` → `dict`
- Counts unique trackIds across the 4 specified categories
- Uses configurable thresholds from `layout_config.json`
- Returns:
  ```python
  {
    'state': 'Low' | 'Med' | 'High',
    'count': int,
    'color': [r, g, b]
  }
  ```
- **Configurable thresholds** (default shown):
  - Low: 0-9 tracks
  - Med: 10-20 tracks  
  - High: 21+ tracks

### `build_state_indicator_html(feature_layer, config_path=None)` → `str` (HTML)
- Single cell table with coloured background
- Shows state text (Low/Med/High)

## 5. Layout Update Helpers

### `update_layout_text_element(aprx, layout_name, element_name, html_content)` → `bool`
- Generic helper to update text element with HTML content
- Works with both textboxes and table elements in APRX

### `load_color_config(config_path=None)` → `dict`
- Loads colour configuration from JSON with hierarchical search:
  1. Explicit `config_path` if provided and exists
  2. Project folder (where .aprx file is located)
  3. Tool installation folder
  4. Built-in default values
- Returns complete config dict with all sections

## 6. Optional: Layout Table Element Creator

### `create_category_table_element(layout, ...)` → `TableElement`
- Creates actual arcpy layout table element
- Alternative to HTML approach if visual formatting meets needs

## File Structure
```
project/
├── layout_config.json              # Project-specific config (optional override)
├── project.aprx
└── Toolbox.pyt/
    ├── layout_helpers.py           # Helper functions (copy into toolbox)
    └── layout_config.json          # Default config (fallback)
```

## Implementation Priority
1. **Phase 1**: Config loader with hierarchy (project → tool → defaults)
2. **Phase 2**: HTML generators with alternating row colors
3. **Phase 3**: Activity state indicator with configurable thresholds
4. **Phase 4**: Geoprocessing-based counting with fgdb persistence
5. **Phase 5**: Layout element update helpers
6. **Phase 6**: Native table element approach (for comparison/testing)

## Error Handling Strategy
- Helper functions raise descriptive exceptions with context
- Main toolbox catches exceptions and reports via `arcpy.AddError()` / `arcpy.AddWarning()`
- Input validation occurs early with clear error messages
- Geoprocessing errors captured and re-raised with context
