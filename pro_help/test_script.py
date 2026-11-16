#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Circle Area Analysis Workflow - Standalone Test Script for ArcGIS Pro

This script tests the adapted geodatabase workflow within ArcGIS Pro.
Run from the Python window in ArcGIS Pro (View > Python).

Requirements:
- ArcGIS Pro 3.7 or later
- Project with a File Geodatabase
- Input CSV files: areas.csv and cities.csv in C:\\data\\ directory
"""

import arcpy


def main():
    """Main workflow execution function."""
    
    print("=" * 60)
    print("Circle Area Analysis Workflow - Test Script")
    print("=" * 60)
    
    # ========================================================================
    # Phase 2.1: Initialize ArcGIS Project
    # ========================================================================
    print("\n[Phase 2.1] Initializing ArcGIS Pro project...")
    try:
        aprx = arcpy.mp.ArcGISProject('CURRENT')
        gdb_path = aprx.workspacePath
        print(f"✓ Successfully initialized project: {aprx.name}")
        print(f"✓ Geodatabase path: {gdb_path}")
    except Exception as e:
        print(f"✗ Failed to initialize ArcGIS Pro project: {e}")
        print("  Note: Must run from within ArcGIS Pro Python window")
        return
    
    # ========================================================================
    # Phase 1.1 & 1.2: Create Point Layers (Geodatabase Feature Classes)
    # ========================================================================
    print("\n[Phase 1.1 & 1.2] Creating point layers from CSV files...")
    
    areas_csv = r"C:\data\areas.csv"
    cities_csv = r"C:\data\cities.csv"
    
    try:
        # Create areas feature class
        arcpy.management.XYTableToPoint(
            input_table=areas_csv,
            output_feature_class=f"{gdb_path}/areas",
            x_field="longitude",
            y_field="latitude",
            coordinate_system="WGS_1984"
        )
        print(f"✓ Created feature class: {gdb_path}/areas")
        
        # Create cities feature class
        arcpy.management.XYTableToPoint(
            input_table=cities_csv,
            output_feature_class=f"{gdb_path}/cities",
            x_field="longitude",
            y_field="latitude",
            coordinate_system="WGS_1984"
        )
        print(f"✓ Created feature class: {gdb_path}/cities")
        
    except Exception as e:
        print(f"✗ Failed to create point layers: {e}")
        return
    
    # ========================================================================
    # Phase 1.3: Buffer Areas (Geodatabase Feature Classes)
    # ========================================================================
    print("\n[Phase 1.3] Creating buffer features...")
    
    try:
        arcpy.analysis.Buffer(
            in_features=f"{gdb_path}/areas",
            out_feature_class=f"{gdb_path}/area_buffers",
            distance=100,
            dissolve_option="NONE",
            method="PLANAR"
        )
        print(f"✓ Created feature class: {gdb_path}/area_buffers")
        
    except Exception as e:
        print(f"✗ Failed to create buffers: {e}")
        return
    
    # ========================================================================
    # Phase 1.4: Summarize Within (Geodatabase Feature Classes)
    # ========================================================================
    print("\n[Phase 1.4] Performing spatial summary analysis...")
    
    try:
        summary_fields = [["population", "Sum"]]
        
        arcpy.analysis.SummarizeWithin(
            in_polygons=f"{gdb_path}/area_buffers",
            in_summary_features=f"{gdb_path}/cities",
            out_feature_class=f"{gdb_path}/summary",
            summary_fields=summary_fields,
            keep_all_input_polygons=True
        )
        print(f"✓ Created feature class: {gdb_path}/summary")
        
    except Exception as e:
        print(f"✗ Failed to perform summarize within: {e}")
        return
    
    # ========================================================================
    # Phase 3.2: Validation - Check Feature Class Properties
    # ========================================================================
    print("\n[Phase 3.2] Validating created feature classes...")
    
    try:
        for fc in [f"{gdb_path}/areas", f"{gdb_path}/cities"]:
            describe = arcpy.Describe(fc)
            print(f"\nFeature class: {fc}")
            print(f"  Type: {describe.type}")
            print(f"  Spatial Reference: {describe.spatialReference.name}")
            print(f"  Is Broken: {describe.isBroken}")
        
        # Check map layers
        m = aprx.listMaps("Circle Analysis")[0]
        print("\nMap layers:")
        for lyr in m.listLayers():
            print(f"  - {lyr.name}: isFeatureLayer={lyr.isFeatureLayer}, isBroken={lyr.isBroken}")
        
    except Exception as e:
        print(f"✗ Failed validation check: {e}")


if __name__ == "__main__":
    main()
