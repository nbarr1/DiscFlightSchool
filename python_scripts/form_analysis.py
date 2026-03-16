import cv2
import mediapipe as mp
import numpy as np
import json
import sys

def calculate_angle(a, b, c):
    """Calculate angle between three points."""
    a = np.array(a)
    b = np.array(b)
    c = np.array(c)
    
    radians = np.arctan2(c[1]-b[1], c[0]-b[0]) - np.arctan2(a[1]-b[1], a[0]-b[0])
    angle = np.abs(radians*180.0/np.pi)
    
    if angle > 180.0:
        angle = 360-angle
        
    return angle

def extract_keypoints(image_path):
    """Extract pose keypoints from image."""
    mp_pose = mp.solutions.pose
    
    image = cv2.imread(image_path)
    if image is None:
        raise ValueError(f"Could not load image: {image_path}")
    
    height, width = image.shape[:2]
    
    with mp_pose.Pose(static_image_mode=True, min_detection_confidence=0.5) as pose:
        image_rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
        results = pose.process(image_rgb)
        
        if not results.pose_landmarks:
            raise ValueError(f"No pose detected in {image_path}")
        
        # Extract keypoints
        landmarks = results.pose_landmarks.landmark
        keypoints = {}
        
        # Map MediaPipe landmarks to our keypoint names
        keypoint_map = {
            'nose': mp_pose.PoseLandmark.NOSE,
            'left_shoulder': mp_pose.PoseLandmark.LEFT_SHOULDER,
            'right_shoulder': mp_pose.PoseLandmark.RIGHT_SHOULDER,
            'left_elbow': mp_pose.PoseLandmark.LEFT_ELBOW,
            'right_elbow': mp_pose.PoseLandmark.RIGHT_ELBOW,
            'left_wrist': mp_pose.PoseLandmark.LEFT_WRIST,
            'right_wrist': mp_pose.PoseLandmark.RIGHT_WRIST,
            'left_hip': mp_pose.PoseLandmark.LEFT_HIP,
            'right_hip': mp_pose.PoseLandmark.RIGHT_HIP,
            'left_knee': mp_pose.PoseLandmark.LEFT_KNEE,
            'right_knee': mp_pose.PoseLandmark.RIGHT_KNEE,
            'left_ankle': mp_pose.PoseLandmark.LEFT_ANKLE,
            'right_ankle': mp_pose.PoseLandmark.RIGHT_ANKLE,
        }
        
        for name, landmark_id in keypoint_map.items():
            lm = landmarks[landmark_id.value]
            keypoints[name] = {
                'x': lm.x,
                'y': lm.y,
                'z': lm.z,
                'visibility': lm.visibility
            }
        
        return keypoints, image

def analyze_form(user_keypoints, pro_keypoints):
    """Compare user form to pro form."""
    
    # Calculate spine angle (shoulder to hip alignment)
    user_spine = calculate_angle(
        [user_keypoints['left_shoulder']['x'], user_keypoints['left_shoulder']['y']],
        [user_keypoints['left_hip']['x'], user_keypoints['left_hip']['y']],
        [user_keypoints['left_knee']['x'], user_keypoints['left_knee']['y']]
    )
    
    pro_spine = calculate_angle(
        [pro_keypoints['left_shoulder']['x'], pro_keypoints['left_shoulder']['y']],
        [pro_keypoints['left_hip']['x'], pro_keypoints['left_hip']['y']],
        [pro_keypoints['left_knee']['x'], pro_keypoints['left_knee']['y']]
    )
    
    # Calculate elbow angle
    user_elbow = calculate_angle(
        [user_keypoints['left_shoulder']['x'], user_keypoints['left_shoulder']['y']],
        [user_keypoints['left_elbow']['x'], user_keypoints['left_elbow']['y']],
        [user_keypoints['left_wrist']['x'], user_keypoints['left_wrist']['y']]
    )
    
    pro_elbow = calculate_angle(
        [pro_keypoints['left_shoulder']['x'], pro_keypoints['left_shoulder']['y']],
        [pro_keypoints['left_elbow']['x'], pro_keypoints['left_elbow']['y']],
        [pro_keypoints['left_wrist']['x'], pro_keypoints['left_wrist']['y']]
    )
    
    spine_diff = user_spine - pro_spine
    elbow_diff = user_elbow - pro_elbow
    
    # Calculate overall match percentage
    max_diff = 30  # Maximum expected difference
    spine_match = max(0, 100 - (abs(spine_diff) / max_diff * 100))
    elbow_match = max(0, 100 - (abs(elbow_diff) / max_diff * 100))
    
    overall_match = (spine_match + elbow_match) / 2
    
    return {
        'percentage_match': overall_match,
        'spine_difference': spine_diff,
        'elbow_difference': elbow_diff,
        'user_spine_angle': user_spine,
        'pro_spine_angle': pro_spine,
        'user_elbow_angle': user_elbow,
        'pro_elbow_angle': pro_elbow,
    }

def main():
    if len(sys.argv) < 3:
        print("Usage: python form_analysis.py <user_image> <pro_image>")
        sys.exit(1)
    
    user_image_path = sys.argv[1]
    pro_image_path = sys.argv[2]
    
    print("Extracting user pose...")
    user_keypoints, user_image = extract_keypoints(user_image_path)
    
    print("Extracting pro pose...")
    pro_keypoints, pro_image = extract_keypoints(pro_image_path)
    
    print("Analyzing form...")
    analysis = analyze_form(user_keypoints, pro_keypoints)
    
    # Add keypoints to output
    analysis['user_keypoints'] = user_keypoints
    analysis['pro_keypoints'] = pro_keypoints
    
    # Save results
    output_path = "output/analysis_results.json"
    with open(output_path, 'w') as f:
        json.dump(analysis, f, indent=2)
    
    print(f"\n✓ Analysis complete!")
    print(f"  Form match: {analysis['percentage_match']:.1f}%")
    print(f"  Spine difference: {analysis['spine_difference']:.2f}°")
    print(f"  Elbow difference: {analysis['elbow_difference']:.2f}°")
    print(f"  Saved to: {output_path}")

if __name__ == "__main__":
    main()