import subprocess
import sys
import os
import shutil
import json

def run_command(command, description):
    """Run a shell command and handle errors."""
    print(f"\n{description}")
    try:
        result = subprocess.run(
            command,
            shell=True,
            check=True,
            capture_output=True,
            text=True
        )
        if result.stdout:
            print(result.stdout)
        return True
    except subprocess.CalledProcessError as e:
        print(f"Error in {command.split()[1]}:")
        print(e.stderr if e.stderr else str(e))
        return False

def copy_to_flutter_assets():
    """Copy output files to Flutter assets directory."""
    output_dir = "output"
    flutter_assets = "../disc_golf_app/assets/data"
    
    # Create Flutter assets directory if it doesn't exist
    os.makedirs(flutter_assets, exist_ok=True)
    
    print("\n[3/3] Copying results to Flutter assets...")
    
    # Copy JSON files
    files_to_copy = [
        "output_coordinates.json",
        "analysis_results.json"
    ]
    
    for filename in files_to_copy:
        src = os.path.join(output_dir, filename)
        dst = os.path.join(flutter_assets, filename)
        
        if os.path.exists(src):
            shutil.copy2(src, dst)
            print(f"      [OK] Copied {filename}")
        else:
            print(f"      [WARNING] {filename} not found")

def print_summary():
    """Print summary of analysis results."""
    try:
        # Read flight tracking data
        with open("output/output_coordinates.json", 'r') as f:
            flight_data = json.load(f)
        
        # Read form analysis data
        with open("output/analysis_results.json", 'r') as f:
            form_data = json.load(f)
        
        print("\n" + "="*60)
        print("ANALYSIS COMPLETE!")
        print("="*60)
        
        print("\nFlight Tracking:")
        print(f"  - Tracked points: {len(flight_data.get('coordinates', []))}")
        print(f"  - Video FPS: {flight_data.get('fps', 0):.2f}")
        print(f"  - Total frames: {flight_data.get('total_frames', 0)}")
        
        print("\nForm Analysis:")
        print(f"  - Form match: {form_data.get('percentage_match', 0):.1f}%")
        print(f"  - Spine difference: {form_data.get('spine_difference', 0):.2f} degrees")
        print(f"  - Elbow difference: {form_data.get('elbow_difference', 0):.2f} degrees")
        
        print("\nOutput files:")
        print("  - output/output_coordinates.json")
        print("  - output/analysis_results.json")
        print("  - disc_golf_app/assets/data/ (Flutter assets)")
        
        print("\n" + "="*60)
        print("Ready to run Flutter app!")
        print("="*60 + "\n")
        
    except Exception as e:
        print(f"\n[WARNING] Could not read summary: {e}")

def main():
    if len(sys.argv) < 4:
        print("Usage: python process_video.py <video_path> <user_image_path> <pro_image_path>")
        print("\nExample:")
        print("  python process_video.py ../test_videos/throw.mp4 ../test_videos/user.jpg ../test_videos/pro.jpg")
        sys.exit(1)
    
    video_path = sys.argv[1]
    user_image = sys.argv[2]
    pro_image = sys.argv[3]
    
    print("="*60)
    print("DISC GOLF ANALYSIS PIPELINE")
    print("="*60)
    
    # Step 1: Track disc flight
    print("\n[1/3] Tracking flight path from video...")
    print(f"      Processing: {video_path}")
    if not run_command(
        f"python track_disc.py {video_path}",
        ""
    ):
        print("\n[ERROR] Flight tracking failed!")
        sys.exit(1)
    
    # Step 2: Analyze throwing form
    print("\n[2/3] Analyzing throwing form...")
    print(f"      User frame: {user_image}")
    print(f"      Pro frame: {pro_image}")
    if not run_command(
        f"python form_analysis.py {user_image} {pro_image}",
        ""
    ):
        print("\n[ERROR] Form analysis failed!")
        sys.exit(1)
    
    # Step 3: Copy results to Flutter
    copy_to_flutter_assets()
    
    # Print summary
    print_summary()

if __name__ == "__main__":
    main()