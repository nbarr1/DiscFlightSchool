import cv2
import numpy as np

class DiscDetector:
    def __init__(self):
        self.min_disc_radius = 10
        self.max_disc_radius = 100
        
    def detect_disc_in_frame(self, frame):
        """Detect disc in a single frame"""
        detections = []
        # Placeholder - will implement full detection later
        return detections
    
    def detect_disc_in_video(self, video_path):
        """Detect disc throughout entire video"""
        all_detections = []
        # Placeholder - will implement full detection later
        return all_detections
