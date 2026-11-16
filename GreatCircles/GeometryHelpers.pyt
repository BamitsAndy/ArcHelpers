"""
ArcGIS Python Toolbox — Geometry Helpers.

Provides geodesic geometry construction tools for ArcGIS Pro. The primary tool,
GreatCircleLines, generates minor arc, major arc, and full great-circle polylines
from a table of origin/destination coordinate pairs by delegating densification to
ArcGIS's native XYToLine (GEODESIC) engine and reassembling the resulting segments.
"""

import arcpy
import os


def _antipode(lat, lon):
    """Return the geographic antipode (diametrically opposite point) of (lat, lon)."""
    a_lat = -lat
    a_lon = lon + 180.0 if lon <= 0 else lon - 180.0
    return a_lat, a_lon


def _extract_points(polyline):
    """Return all parts of a polyline as a list of point lists."""
    parts = []
    for i in range(polyline.partCount):
        part = polyline.getPart(i)
        parts.append([part.getObject(j) for j in range(part.count)])
    return parts


def _merge_segments(segments, sr):
    """
    Combine multiple geodesic polyline segments into a single multi-part polyline.

    Each segment's parts are preserved as-is rather than stitched end-to-end.
    Stitching by concatenating point arrays risks inserting planar connector
    segments at junctions where an antimeridian-split half ends on the boundary
    instead of at the true geographic junction. ArcGIS Pro renders parts that
    share endpoint coordinates as a visually continuous line.
    """
    all_parts = []
    for seg in segments:
        all_parts.extend(_extract_points(seg))
    arr = arcpy.Array([arcpy.Array(p) for p in all_parts])
    return arcpy.Polyline(arr, sr)


_SKIP_FIELD_NAMES = {"Shape", "Shape_Length", "Shape_Area", "SHAPE"}

# arcpy.Field.type strings that need remapping to AddField type keywords.
_FIELD_TYPE_MAP = {
    "String":       "TEXT",
    "Single":       "FLOAT",
    "SmallInteger": "SHORT",
    "Integer":      "LONG",
}


def _validate_coords(olat, olon, dlat, dlon):
    """
    Validate an origin/destination coordinate pair.

    Returns (True, "") on success, or (False, reason) describing why the pair
    is unusable: NULL values, out-of-range latitude/longitude, identical points,
    or antipodal points (where the great circle is geometrically undefined).
    """
    if any(v is None for v in (olat, olon, dlat, dlon)):
        return False, "one or more coordinate values are NULL"
    if abs(olat) > 90:
        return False, f"origin latitude {olat} out of range [-90, 90]"
    if abs(dlat) > 90:
        return False, f"destination latitude {dlat} out of range [-90, 90]"
    if abs(olon) > 180:
        return False, f"origin longitude {olon} out of range [-180, 180]"
    if abs(dlon) > 180:
        return False, f"destination longitude {dlon} out of range [-180, 180]"
    if abs(olat - dlat) < 1e-9 and abs(olon - dlon) < 1e-9:
        return False, "origin and destination are the same point"
    a_lat, a_lon = _antipode(olat, olon)
    if abs(a_lat - dlat) < 1e-9 and abs(a_lon - dlon) < 1e-9:
        return False, "origin and destination are antipodal — great circle is undefined"
    return True, ""


def _get_passthrough_fields(in_table):
    """Return non-required, non-geometry fields eligible for passthrough to the output."""
    return [
        f for f in arcpy.ListFields(in_table)
        if not f.required and f.name not in _SKIP_FIELD_NAMES
    ]


class Toolbox:
    """ArcGIS Python Toolbox registration class."""

    def __init__(self):
        self.label = "Geometry Helpers"
        self.alias = "GeometryHelpers"
        self.tools = [GreatCircleLines]


class GreatCircleLines:
    """
    ArcGIS tool: Great Circle Lines.

    Reads origin and destination lat/lon columns from an input table and writes
    three geodesic polyline features per valid row — MINOR_ARC, MAJOR_ARC, and
    GREAT_CIRCLE — to the output feature class. Non-coordinate attribute fields
    are copied through unchanged.

    Implementation strategy:
      Each origin/destination pair defines four geodesic segments that together
      span the full great circle: O→D, D→O-antipode, O-antipode→D-antipode, and
      D-antipode→O. These are written to an in-memory table and converted to
      geodesic lines via XYToLine (GEODESIC), which handles antimeridian splitting
      automatically. The four segments are then reassembled into the three output
      arc types.
    """

    def __init__(self):
        self.label = "Great Circle Lines"
        self.description = (
            "Creates geodesic great-circle features (MINOR_ARC, MAJOR_ARC, GREAT_CIRCLE) "
            "from a table of origin/destination coordinate pairs."
        )
        self.canRunInBackground = False

    def getParameterInfo(self):
        """Define tool parameters."""
        in_table = arcpy.Parameter(
            displayName="Input Table",
            name="in_table",
            datatype="DETable",
            parameterType="Required",
            direction="Input",
        )

        origin_lat_field = arcpy.Parameter(
            displayName="Origin Latitude Field",
            name="origin_lat_field",
            datatype="Field",
            parameterType="Required",
            direction="Input",
        )
        origin_lat_field.parameterDependencies = [in_table.name]
        origin_lat_field.filter.list = ["Double", "Single", "Long", "Short"]

        origin_lon_field = arcpy.Parameter(
            displayName="Origin Longitude Field",
            name="origin_lon_field",
            datatype="Field",
            parameterType="Required",
            direction="Input",
        )
        origin_lon_field.parameterDependencies = [in_table.name]
        origin_lon_field.filter.list = ["Double", "Single", "Long", "Short"]

        dest_lat_field = arcpy.Parameter(
            displayName="Destination Latitude Field",
            name="dest_lat_field",
            datatype="Field",
            parameterType="Required",
            direction="Input",
        )
        dest_lat_field.parameterDependencies = [in_table.name]
        dest_lat_field.filter.list = ["Double", "Single", "Long", "Short"]

        dest_lon_field = arcpy.Parameter(
            displayName="Destination Longitude Field",
            name="dest_lon_field",
            datatype="Field",
            parameterType="Required",
            direction="Input",
        )
        dest_lon_field.parameterDependencies = [in_table.name]
        dest_lon_field.filter.list = ["Double", "Single", "Long", "Short"]

        out_feature_class = arcpy.Parameter(
            displayName="Output Feature Class",
            name="out_feature_class",
            datatype="DEFeatureClass",
            parameterType="Required",
            direction="Output",
        )

        return [
            in_table,
            origin_lat_field,
            origin_lon_field,
            dest_lat_field,
            dest_lon_field,
            out_feature_class,
        ]

    def isLicensed(self):
        return True

    def updateParameters(self, parameters):
        return

    def updateMessages(self, parameters):
        return

    def execute(self, parameters, messages):
        """Run the tool: build geodesic arc features and write to the output feature class."""
        in_table = parameters[0].valueAsText
        olat_fld = parameters[1].valueAsText
        olon_fld = parameters[2].valueAsText
        dlat_fld = parameters[3].valueAsText
        dlon_fld = parameters[4].valueAsText
        out_fc   = parameters[5].valueAsText

        sr = arcpy.SpatialReference(4326)

        pt_fields   = _get_passthrough_fields(in_table)
        pt_names    = [f.name for f in pt_fields]
        coord_names = [olat_fld, olon_fld, dlat_fld, dlon_fld]
        coord_set   = set(coord_names)
        extra_names = [n for n in pt_names if n not in coord_set]
        cursor_fields = coord_names + extra_names
        name_to_idx   = {n: i for i, n in enumerate(cursor_fields)}

        row_attrs = {}
        skipped   = 0
        total     = int(arcpy.management.GetCount(in_table)[0])

        # Staging table: one row per geodesic segment (4 segments per input row).
        if arcpy.Exists("memory/gc_segs"):
            arcpy.management.Delete("memory/gc_segs")
        arcpy.management.CreateTable("memory", "gc_segs")
        for fname, ftype in [
            ("gc_id", "LONG"),    # encodes both row index (// 4) and segment index (% 4)
            ("gc_sx", "DOUBLE"),
            ("gc_sy", "DOUBLE"),
            ("gc_ex", "DOUBLE"),
            ("gc_ey", "DOUBLE"),
        ]:
            arcpy.management.AddField("memory/gc_segs", fname, ftype)

        seg_fields = ["gc_id", "gc_sx", "gc_sy", "gc_ex", "gc_ey"]
        row_id    = 0
        input_row = 0

        arcpy.SetProgressor("step", "Processing rows...", 0, total, 1)

        with arcpy.da.SearchCursor(in_table, cursor_fields) as sc, \
             arcpy.da.InsertCursor("memory/gc_segs", seg_fields) as ic:
            for row in sc:
                input_row += 1
                arcpy.SetProgressorLabel(f"Processing row {input_row} of {total}...")
                arcpy.SetProgressorPosition(input_row)
                try:
                    olat = float(row[0])
                    olon = float(row[1])
                    dlat = float(row[2])
                    dlon = float(row[3])
                except (TypeError, ValueError):
                    arcpy.AddWarning(
                        f"Input row {input_row}: cannot convert coordinate to float — skipped"
                    )
                    skipped += 1
                    continue

                ok, reason = _validate_coords(olat, olon, dlat, dlon)
                if not ok:
                    arcpy.AddWarning(f"Input row {input_row}: {reason} — skipped")
                    skipped += 1
                    continue

                oa_lat, oa_lon = _antipode(olat, olon)
                da_lat, da_lon = _antipode(dlat, dlon)

                # Four segments covering the full great circle (arcpy uses x=lon, y=lat):
                #   seg 0 (id*4+0): O  → D   — the minor arc
                #   seg 1 (id*4+1): D  → OA  — first half of the major arc
                #   seg 2 (id*4+2): OA → DA  — second half of the major arc
                #   seg 3 (id*4+3): DA → O   — closes the great circle
                ic.insertRow([row_id * 4 + 0, olon,   olat,   dlon,   dlat  ])
                ic.insertRow([row_id * 4 + 1, dlon,   dlat,   oa_lon, oa_lat])
                ic.insertRow([row_id * 4 + 2, oa_lon, oa_lat, da_lon, da_lat])
                ic.insertRow([row_id * 4 + 3, da_lon, da_lat, olon,   olat  ])

                row_attrs[row_id] = [row[name_to_idx[n]] for n in pt_names]
                row_id += 1

        # Convert staged segment endpoints to geodesic polylines via XYToLine.
        if arcpy.Exists("memory/gc_seg_lines"):
            arcpy.management.Delete("memory/gc_seg_lines")
        arcpy.management.XYToLine(
            "memory/gc_segs", "memory/gc_seg_lines",
            "gc_sx", "gc_sy", "gc_ex", "gc_ey",
            "GEODESIC", "gc_id", sr,
        )

        # Index resulting geometries by (row_id, segment_index).
        seg_geoms = {}
        with arcpy.da.SearchCursor(
            "memory/gc_seg_lines", ["SHAPE@", "gc_id"]
        ) as sc:
            for geom, gc_id_val in sc:
                rid = gc_id_val // 4
                sid = gc_id_val % 4 + 1   # 1-based for readability below
                seg_geoms.setdefault(rid, {})[sid] = geom

        # Build output in memory to avoid edit-session schema locks on the target GDB.
        mem_out = "memory/gc_out_temp"
        if arcpy.Exists(mem_out):
            arcpy.management.Delete(mem_out)
        arcpy.management.CreateFeatureclass("memory", "gc_out_temp", "POLYLINE", spatial_reference=sr)
        arcpy.management.AddField(mem_out, "line_type", "TEXT", field_length=20)

        out_pt_fields = []
        for f in pt_fields:
            if f.name.lower() == "line_type":
                arcpy.AddWarning(
                    f"Passthrough field '{f.name}' conflicts with reserved field 'line_type' — skipped"
                )
                continue
            ftype = _FIELD_TYPE_MAP.get(f.type, f.type)
            kwargs = {"field_length": f.length} if f.type == "String" else {}
            arcpy.management.AddField(mem_out, f.name, ftype, **kwargs)
            out_pt_fields.append(f)

        out_pt_indices = [pt_names.index(f.name) for f in out_pt_fields]
        insert_fields = ["SHAPE@", "line_type"] + [f.name for f in out_pt_fields]

        with arcpy.da.InsertCursor(mem_out, insert_fields) as ic:
            for rid in sorted(seg_geoms):
                segs  = seg_geoms[rid]
                attrs = [row_attrs[rid][i] for i in out_pt_indices]

                minor_arc    = segs[1]
                major_arc    = _merge_segments([segs[2], segs[3], segs[4]], sr)
                great_circle = _merge_segments([segs[1], segs[2], segs[3], segs[4]], sr)

                ic.insertRow([minor_arc,    "MINOR_ARC"]    + attrs)
                ic.insertRow([major_arc,    "MAJOR_ARC"]    + attrs)
                ic.insertRow([great_circle, "GREAT_CIRCLE"] + attrs)

        if arcpy.Exists(out_fc):
            arcpy.management.Delete(out_fc)
        arcpy.management.CopyFeatures(mem_out, out_fc)

        arcpy.management.Delete("memory/gc_segs")
        arcpy.management.Delete("memory/gc_seg_lines")
        arcpy.management.Delete(mem_out)

        arcpy.ResetProgressor()
        written = (row_id) * 3
        arcpy.AddMessage(
            f"GreatCircleLines complete: {written} feature(s) written to {out_fc}"
            + (f"; {skipped} input row(s) skipped due to invalid coordinates" if skipped else "")
        )

    def postExecute(self, parameters):
        return
