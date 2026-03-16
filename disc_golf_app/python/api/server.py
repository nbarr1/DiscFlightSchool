from flask import Flask, request, jsonify
from flask_cors import CORS
import sys
import os

# Add parent directory to path
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

app = Flask(__name__)
CORS(app)

@app.route('/api/health', methods=['GET'])
def health_check():
    return jsonify({'status': 'ok', 'message': 'Server is running'})

@app.route('/api/track-flight', methods=['POST'])
def track_flight():
    try:
        if 'video' not in request.files:
            return jsonify({'error': 'No video file provided'}), 400
        
        return jsonify({
            'success': True,
            'message': 'Flight tracking endpoint ready'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/analyze-form', methods=['POST'])
def analyze_form():
    try:
        if 'video' not in request.files:
            return jsonify({'error': 'No video file provided'}), 400
        
        return jsonify({
            'success': True,
            'message': 'Form analysis endpoint ready'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    print("=" * 50)
    print("  Disc Golf API Server")
    print("=" * 50)
    print("Server running on http://localhost:5000")
    print("Press CTRL+C to quit")
    print("=" * 50)
    app.run(host='0.0.0.0', port=5000, debug=True)
