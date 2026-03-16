import cv2
import numpy as np
import json
import sys

def track_disc(video_path):
    """
    Track the disc in a video and return its coordinates over time.
    """
    cap = cv2.VideoCapture(video_path)
    
    if not cap.isOpened():
        raise ValueError(f"Could not open video: {video_path}")
    
    # Get video properties
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    
    print(f"Video loaded: {total_frames} frames at {fps} FPS")
    
    coordinates = []
    frame_number = 0
    
    # Color range for disc detection (adjust based on your disc color)
    # This is for a bright colored disc (orange/yellow)
    lower_color = np.array([10, 100, 100])
    upper_color = np.array([30, 255, 255])
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        
        # Convert to HSV for better color detection
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        
        # Create mask for disc color
        mask = cv2.inRange(hsv, lower_color, upper_color)
        
        # Apply morphological operations to reduce noise
        kernel = np.ones((5,5), np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
        
        # Find contours
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        
        if contours:
            # Find the largest contour (assumed to be the disc)
            largest_contour = max(contours, key=cv2.contourArea)
            area = cv2.contourArea(largest_contour)
            
            # Only track if contour is large enough
            if area > 50:
                # Get the center of the contour
                M = cv2.moments(largest_contour)
                if M["m00"] != 0:
                    cx = int(M["m10"] / M["m00"])
                    cy = int(M["m01"] / M["m00"])
                    
                    coordinates.append({
                        "x": cx,
                        "y": cy,
                        "frame": frame_number
                    })
                    
                    # Optional: Draw on frame for visualization
                    cv2.circle(frame, (cx, cy), 5, (0, 255, 0), -1)
        
        frame_number += 1
        
        # Show progress
        if frame_number % 30 == 0:
            print(f"Processed {frame_number}/{total_frames} frames...")
    
    cap.release()
    
    print(f"Tracking complete! Found {len(coordinates)} disc positions.")
    return coordinates

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python flight_path_tracker.py <video_path>")
        sys.exit(1)
    
    video_path = sys.argv[1]
    
    try:
        coordinates = track_disc(video_path)
        
        # Create output directory if it doesn't exist
        import os
        os.makedirs('output', exist_ok=True)
        
        # Save coordinates to JSON
        with open('output/output_coordinates.json', 'w') as f:
            json.dump(coordinates, f, indent=2)
        
        print("[OK] Coordinates saved to output/output_coordinates.json")
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)