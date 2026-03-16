import cv2
import mediapipe as mp
import numpy as np

print("Testing imports...")
print(f"✓ OpenCV version: {cv2.__version__}")
print(f"✓ MediaPipe version: {mp.__version__}")
print(f"✓ NumPy version: {np.__version__}")

print("\nTesting MediaPipe Pose...")
mp_pose = mp.solutions.pose
with mp_pose.Pose() as pose:
    print("✓ MediaPipe Pose initialized successfully")

print("\nTesting Kalman Filter...")
kalman = cv2.KalmanFilter(4, 2)
print("✓ Kalman Filter initialized successfully")

print("\n" + "="*50)
print("ALL TESTS PASSED!")
print("="*50)
print("\nYou're ready to process videos!")