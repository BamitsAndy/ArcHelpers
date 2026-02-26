# ArcGIS Pro Layout Helper Functions - Design Document
**Date:** 2026-02-17

---

## Problem Statement
Design ArcGIS Pro layout helper functions to automate layout elements including category tables and activity state indicators. The functions need to:
- Display HTML tables with alternating row colors
- Integrate with ArcGIS toolbox error messaging
- Support configurable thresholds and file locations
- Efficiently count unique track IDs using geoprocessing

---

## Findings by Branch

### 1. HTML Table Rendering with Alternating Row Colors

**Decision:** Use **inline CSS styles** per table row.

**Rationale:**
- ArcGIS Pro text elements support inline styles reliably
- The `<style>` tag approach may not work in ArcGIS Pro's HTML subset
- Explicit control per row ensures the alternating Dark Grey / Lighter Grey pattern works consistently

**Implementation Pattern:**
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

**Row Colors:**
- Odd rows: `rgb(64, 64, 64)` (Dark Grey)
- Even rows: `rgb(80, 80, 80)` (Slightly lighter grey)

---

### 2. Error Handling for ArcGIS Toolbox Integration

**Decision:** Use **descriptive exception raising** with clear error messages.

**Rationale:**
- Functions will be copied into the primary toolbox and called internally
- The toolbox's main code should handle arcpy.AddError() / AddWarning() calls
- Helper functions should focus on raising meaningful exceptions with context

**Implementation Pattern:**
```python
def get_category_track_counts(feature_layer, category_field='class', track_id_field='trackId'):
    """Get unique track counts per category."""
    # Validate inputs
    if not arcpy.Exists(feature_layer):
        raise ValueError(f"Feature layer not found: {feature_layer}")
    
    # Check fields exist
    fields = [f.name for f in arcpy.ListFields(feature_layer)]
    if category_field not in fields:
        raise ValueError(f"Category field '{category_field}' not found in {feature_layer}")
    if track_id_field not in fields:
        raise ValueError(f"Track ID field '{track_id_field}' not found in {feature_layer}")
    
    # ... function logic ...
```

**Toolbox Integration Pattern:**
```python
# In the main toolbox script
try:
    result = layout_helpers.get_category_track_counts(layer)
except ValueError as e:
    arcpy.AddError(str(e))
    raise  # Re-raise to stop execution
except Exception as e:
    arcpy.AddError(f"Unexpected error: {str(e)}")
    raise
```

---

### 3. Configuration File Search Hierarchy

**Decision:** **Hybrid search** - explicit paths parameter with smart fallbacks.

**Hierarchy:**
1. Explicit `config_path` parameter if provided
2. Project folder (where .aprx file is located)
3. Tool installation folder (where the script/toolbox resides)
4. Fallback to default values built into the code

**Implementation Pattern:**
```python
def load_color_config(config_path=None):
    """Load color configuration from JSON with hierarchy search."""
    
    # 1. Use explicit path if provided
    if config_path and os.path.exists(config_path):
        with open(config_path, 'r') as f:
            return json.load(f)
    
    # 2. Search project folder
    project_path = get_project_folder()  # From arcpy.mp.ArcGISProject
    config_in_project = os.path.join(project_path, 'layout_config.json')
    if os.path.exists(config_in_project):
        with open(config_in_project, 'r') as f:
            return json.load(f)
    
    # 3. Search tool folder
    tool_folder = get_tool_folder()  # From __file__ or arcpy.GetInstallInfo()
    config_in_tool = os.path.join(tool_folder, 'layout_config.json')
    if os.path.exists(config_in_tool):
        with open(config_in_tool, 'r') as f:
            return json.load(f)
    
    # 4. Return defaults
    return get_default_config()
```

---

### 4. Activity Thresholds in Configuration

**Decision:** Move thresholds to config with **explicit range format**.

**Rationale:**
- Explicit ranges are clearer and more flexible
- Supports non-contiguous ranges if needed in future
- Each state has its own color definition

**Config Structure:**
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

**Evaluation Logic:**
```python
def get_activity_state(count, config):
    """Determine activity state based on count and config thresholds."""
    thresholds = config['activity_thresholds']
    
    for state, settings in thresholds.items():
        min_val = settings.get('min', 0)
        max_val = settings.get('max', float('inf'))
        
        if min_val <= count <= max_val:
            return {
                'state': state,
                'count': count,
                'color': settings['color']
            }
    
    # Fallback
    return {'state': 'Unknown', 'count': count, 'color': [128, 128, 128]}
```

---

### 5. Efficient Unique TrackId Counting

**Decision:** Use **arcpy.analysis.Statistics** tool with CASE_FIELD for category grouping, outputting to fgdb.

**Rationale:**
- Native ArcGIS tool is optimized for large datasets
- Supports direct output to file geodatabase (persistence)
- Properly handles unique counting via FREQUENCY option

**Implementation Pattern:**
```python
def get_category_track_counts(feature_layer, category_field='class', 
                              track_id_field='trackId', 
                              output_table=None):
    """
    Get unique track counts per category using Summary Statistics.
    
    Args:
        feature_layer: Input feature layer
        category_field: Field containing category values
        track_id_field: Field containing track identifiers
        output_table: Optional path to persist results (default: in_memory)
    
    Returns:
        dict: {category: set of unique trackIds}
    """
    # Validate inputs
    if not arcpy.Exists(feature_layer):
        raise ValueError(f"Feature layer not found: {feature_layer}")
    
    # Determine output location
    if output_table is None:
        output_table = r"in_memory\category_summary"
    
    try:
        # Use Summary Statistics tool
        # This creates a table with unique combinations
        arcpy.analysis.Statistics(
            in_table=feature_layer,
            out_table=output_table,
            statistics_fields=[[track_id_field, "COUNT"]],
            case_field=[category_field, track_id_field]
        )
        
        # Read results and aggregate by category
        category_counts = {}
        with arcpy.da.SearchCursor(output_table, [category_field, track_id_field]) as cursor:
            for row in cursor:
                category = row[0]
                track_id = row[1]
                
                if category not in category_counts:
                    category_counts[category] = set()
                category_counts[category].add(track_id)
        
        # Convert sets to counts for return
        return {cat: len(tracks) for cat, tracks in category_counts.items()}
        
    except arcpy.ExecuteError as e:
        raise RuntimeError(f"Geoprocessing error: {arcpy.GetMessages(2)}") from e
```

**Alternative: Direct FGDB Persistence**
If the summary table should be persisted permanently:
```python
# In default fgdb
fgdb_path = arcpy.env.workspace or arcpy.env.scratchGDB
output_table = os.path.join(fgdb_path, "CategoryTrackSummary")

# Call with persistence
result = get_category_track_counts(layer, output_table=output_table)
```

---

## Recommended Approach

### File Structure
```
project/
├── layout_config.json              # Project-specific config (optional)
├── Toolbox.pyt/
│   ├── layout_helpers.py           # Helper functions (copy into here)
│   └── layout_config.json          # Default config (fallback)
└── project.aprx
```

### Implementation Order
1. **Phase 1:** Config loader with hierarchy + default fallbacks
2. **Phase 2:** HTML table generators (static + dynamic)
3. **Phase 3:** Activity state indicator with threshold config
4. **Phase 4:** Geoprocessing-based counting with fgdb persistence
5. **Phase 5:** Layout element update helpers

### Key Design Principles
1. **Fail fast with clear errors** - Validate inputs and raise descriptive exceptions
2. **Config-driven** - Colors, thresholds, and ordering all externalized
3. **ArcGIS-native** - Use geoprocessing tools where they add value
4. **Flexible persistence** - Support both in-memory and fgdb output

### Sample Usage Flow
```python
# 1. Load config (auto-searches hierarchy)
config = load_color_config()

# 2. Get category counts (with fgdb persistence)
counts = get_category_track_counts(
    "TracksLayer", 
    output_table=r"C:\Project\Data.gdb\TrackSummary"
)

# 3. Generate HTML table
html = build_static_category_table("TracksLayer", config)

# 4. Update layout element
update_layout_text_element(aprx, "Layout1", "CategoryTable", html)

# 5. Get activity state
state = get_activity_state(sum(counts.values()), config)
```

---

## Next Steps
1. Update PLAN.md with these finalized decisions
2. Create layout_config.json template
3. Implement helper functions following these patterns
4. Write integration tests for toolbox context
