-- Which image, video, audio and PDF formats zettle saves, and how to recognize them.

local EXTENSIONS = {
	png = true,
	jpg = true,
	jpeg = true,
	gif = true,
	webp = true,
	svg = true,
	bmp = true,
	tiff = true,
	tif = true,
	ico = true,
	avif = true,
	heic = true,
	jxl = true,
	-- video
	mp4 = true,
	webm = true,
	mkv = true,
	avi = true,
	mov = true,
	-- audio
	m4a = true,
	mp3 = true,
	ogg = true,
	opus = true,
	wav = true,
	flac = true,
	-- documents
	pdf = true,
}

return {
	EXTENSIONS = EXTENSIONS,
}
