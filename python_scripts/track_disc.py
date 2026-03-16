import cv2
import numpy as np
import json
import sys
import os

def track_disc(video_path, output_path="output/output_coordinates.json"):
    """
    Track disc movement in video using color detection and motion tracking.
    """
    
    # Open video
    cap = cv2.VideoCapture(video_path)
    
    if not cap.isOpened():
        raise ValueError(f"Could not open video: {video_path}")
    
    # Get video properties
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    
    print(f"Video loaded: {total_frames} frames at {fps} FPS")
    
    coordinates = []
    frame_number = 0
    
    # Color range for disc detection (adjust based on disc color)
    # Default: bright colors (white, yellow, orange, pink discs)
    lower_color = np.array([0, 0, 150])  # HSV lower bound
    upper_color = np.array([180, 100, 255])  # HSV upper bound
    
    while True:
        ret, frame = cap.read()
        
        if not ret:
            break
        
        frame_number += 1
        
        # Convert to HSV for better color detection
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        
        # Create mask for disc color
        mask = cv2.inRange(hsv, lower_color, upper_color)
        
        # Apply morphological operations to reduce noise
        kernel = np.ones((5, 5), np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
        
        # Find contours
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        
        if contours:
            # Find the largest contour (likely the disc)
            largest_contour = max(contours, key=cv2.contourArea)
            area = cv2.contourArea(largest_contour)
            
            # Only track if area is significant (not noise)
            if area > 50:  # Minimum area threshold
                # Get centroid
                M = cv2.moments(largest_contour)
                if M["m00"] != 0:
                    cx = int(M["m10"] / M["m00"])
                    cy = int(M["m01"] / M["m00"])
                    
                    # Store coordinate
                    coordinates.append({
                        "frame": frame_number,
                        "x": cx,
                        "y": cy,
                        "timestamp": frame_number / fps
                    })
        
        # Progress indicator
        if frame_number % 30 == 0:
            print(f"Processed {frame_number}/{total_frames} frames...")
    
    cap.release()
    
    print(f"Tracking complete! Found {len(coordinates)} disc positions.")
    
    # Create output directory
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    # Save results
    output_data = {
        "coordinates": coordinates,
        "video_info": {
            "fps": fps,
            "total_frames": total_frames,
            "width": width,
            "height": height,
            "duration_seconds": total_frames / fps
        },
        "fps": fps,
        "total_frames": total_frames
    }
    
    with open(output_path, 'w') as f:
        json.dump(output_data, f, indent=2)
    
    print(f"[OK] Coordinates saved to {output_path}")
    
    return output_data

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python track_disc.py <video_path>")
        sys.exit(1)
    
    video_path = sys.argv[1]
    
    try:
        track_disc(video_path)
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)