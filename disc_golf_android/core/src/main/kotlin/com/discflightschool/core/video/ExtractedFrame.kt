package com.discflightschool.core.video

/**
 * One extracted video frame, tagged with the frame index it was sampled at.
 *
 * The index is carried explicitly rather than implied by list position:
 * extraction can skip a frame mid-video, and using list position would then
 * shift every later frame's timestamp relative to the actual video.
 */
data class ExtractedFrame(val index: Int, val path: String)
