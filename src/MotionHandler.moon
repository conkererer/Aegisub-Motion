local log, Line, LineCollection, Math, tags, Transform
version = '1.1.7'

haveDepCtrl, DependencyControl = pcall require, 'l0.DependencyControl'

if haveDepCtrl
	version = DependencyControl {
		name: 'MotionHandler'
		:version
		description: 'A class for applying motion data to a LineCollection.'
		author: 'torque'
		url: 'https://github.com/TypesettingTools/Aegisub-Motion'
		moduleName: 'a-mo.MotionHandler'
		feed: 'https://raw.githubusercontent.com/TypesettingTools/Aegisub-Motion/DepCtrl/DependencyControl.json'
		{
			{ 'a-mo.Log',            version: '1.0.0'            }
			{ 'a-mo.Line',           version: '1.5.2'           }
			{ 'a-mo.LineCollection', version: '1.2.0' }
			{ 'a-mo.Math',           version: '1.0.0'           }
			{ 'a-mo.Tags',           version: '1.3.3'           }
			{ 'a-mo.Transform',      version: '1.2.4'      }
		}
	}
	log, Line, LineCollection, Math, tags, Transform = version\requireModules!

else
	Line           = require 'a-mo.Line'
	LineCollection = require 'a-mo.LineCollection'
	log            = require 'a-mo.Log'
	Math           = require 'a-mo.Math'
	tags           = require 'a-mo.Tags'
	Transform      = require 'a-mo.Transform'

class MotionHandler
	@version: version

	new: ( @lineCollection, mainData, rectClipData = { }, vectClipData = { } ) =>
		-- Create a local reference to the options table.
		@options = @lineCollection.options
		@lineTrackingData = mainData.dataObject
		@rectClipData = rectClipData.dataObject
		@vectClipData = vectClipData.dataObject
		@xDelta = 0
		@yDelta = 0

		@callbacks = { }

		-- Do NOT perform any normal callbacks if mainData is shake
		-- rotoshape. In theory it would be possible to do plain translation
		-- because the SRS data contains a center_x and center_y field for
		-- each frame.
		unless 'SRS' == mainData.type or @options.main.clipOnly
			if @options.main.xPosition or @options.main.yPosition or @options.main.xScale or @options.main.zRotation

				if @options.main.absPos
					@callbacks["(\\pos)%(([%-%d%.]+,[%-%d%.]+)%)"] = absolutePosition
				else
					@callbacks["(\\pos)%(([%-%d%.]+,[%-%d%.]+)%)"] = position

			if @options.main.origin
				@callbacks["(\\org)%(([%-%d%.]+,[%-%d%.]+)%)"] = origin

			if @options.main.xScale then
				@callbacks["(\\fsc[xy])([%d%.]+)"] = scale
				if @options.main.border
					@callbacks["(\\[xy]?bord)([%d%.]+)"] = scale
				if @options.main.shadow
					@callbacks["(\\[xy]?shad)([%-%d%.]+)"] = scale
				if @options.main.blur
					@callbacks["(\\blur)([%d%.]+)"] = blur

			if @options.main.zRotation
				@callbacks["(\\frz?)([%-%d%.]+)"] = rotate

		-- Don't support SRS for rectangular clips.
		if @rectClipData and 'SRS' != rectClipData.type
			@callbacks['(\\i?clip)(%([%-%d%.]+,[%-%d%.]+,[%-%d%.]+,[%-%d%.]+%))'] = rectangularClip

		if @vectClipData
			if 'SRS' == vectClipData.type
				@callbacks['(\\i?clip)(%([^,]-%))'] = vectorClipSRS
			else
				@callbacks['(\\i?clip)(%([^,]-%))'] = vectorClip

		@resultingCollection = LineCollection @lineCollection.sub
		@resultingCollection.shouldInsertLines = true
		@resultingCollection.options = @options
		-- This has to be copied over for clip interpolation
		@resultingCollection.meta = @lineCollection.meta
		for line in *@lineCollection.lines
			if @options.main.linear and not (@options.main.origin and line.hasOrg) and not ((@rectClipData or @vectClipData) and line.hasClip)
				line.method = linear
			else
				line.method = nonlinear

	applyMotion: =>
		setProgress = aegisub.progress.set
		setProgress 0

		totalLines = #@lineCollection.lines
		-- The lines are collected in reverse order in LineCollection so
		-- that we don't need to do things in reverse here.
		insertNumber = @lineCollection.lines[totalLines].number
		for index = 1, totalLines
			with line = @lineCollection.lines[index]

				-- start frame of line relative to start frame of tracked data
				.relativeStart = .startFrame - @lineCollection.startFrame + 1
				-- end frame of line relative to start frame of tracked data
				.relativeEnd = .endFrame - @lineCollection.startFrame
				.number = insertNumber
				.method @, line

			setProgress index/totalLines*100

		return @resultingCollection

	linear = ( line ) =>
		moveTag = tags.allTags.move
		posTag = tags.allTags.pos
		with line
			startFrameTime = aegisub.ms_from_frame aegisub.frame_from_ms .start_time
			frameAfterStartTime = aegisub.ms_from_frame aegisub.frame_from_ms( .start_time ) + 1
			frameBeforeEndTime = aegisub.ms_from_frame aegisub.frame_from_ms( .end_time ) - 1
			endFrameTime = aegisub.ms_from_frame aegisub.frame_from_ms .end_time
			-- Calculates the time length (in ms) from the start of the first
			-- subtitle frame to the actual start of the line time.
			beginTime = math.floor 0.5*(startFrameTime + frameAfterStartTime) - .start_time
			-- Calculates the total length of the line plus the difference
			-- (which is negative) between the start of the last frame the
			-- line is on and the end time of the line.
			endTime = math.floor 0.5*(frameBeforeEndTime + endFrameTime) - .start_time

			if .move
				.text = .text\gsub moveTag.pattern, ->
					move = .move
					progress = (.start_time - move.start)/(move.end - move.start)
					return posTag\format moveTag\interpolate {move.x1, move.y1}, {move.x2, move.y2}, progress

			for pattern, callback in pairs @callbacks
				log.checkCancellation!
				.text = .text\gsub pattern, ( tag, value ) ->
					values = { }
					for frame in *{ .relativeStart, .relativeEnd }
						@lineTrackingData\calculateCurrentState frame
						values[#values+1] = callback @, value, frame
					("%s%s\\t(%d,%d,%s%s)")\format tag, values[1], beginTime, endTime, tag, values[2]

			if @options.main.xPosition or @options.main.yPosition
				.text = .text\gsub "\\pos(%b())\\t%((%d+,%d+),\\pos(%b())%)", ( start, time, finish ) ->
					"\\move" .. start\sub( 1, -2 ) .. ',' .. finish\sub( 2, -2 ) .. ',' .. time .. ")"

			@resultingCollection\addLine Line( line, nil, { wasLinear: true } ), nil, true, true

	nonlinear = ( line ) =>
		moveTag = tags.allTags.move
		posTag = tags.allTags.pos
		for frame = line.relativeEnd, line.relativeStart, -1
			with line

				log.checkCancellation!

				newStartTime = math.floor(math.max(0, aegisub.ms_from_frame( @lineCollection.startFrame + frame - 1 ))/10)*10
				newEndTime   = math.floor(aegisub.ms_from_frame( @lineCollection.startFrame + frame )/10)*10

				timeDelta = newStartTime - math.floor(math.max(0,aegisub.ms_from_frame( @lineCollection.startFrame + .relativeStart - 1 ))/10)*10

				local newText
				if @options.main.killTrans
					newText = line\interpolateTransformsCopy timeDelta, newStartTime
				else
					newText = line\detokenizeTransformsCopy timeDelta

				newText = newText\gsub "\\fade(%b())", ( fade ) ->
					a1, a2, a3, t1, t2, t3, t4 = fade\match("(%d+),(%d+),(%d+),(%d+),(%d+),(%d+),(%d+)")
					if t1 == nil
						message = "There is a malformed \\fade you must fix.\n\\fade requires 7 integer arguments.\nLine: #{.number}, tag: \\fade(#{fade})."
						if fade\match("(%d+),(%d+)")
							message ..= "\nPerhaps you meant to use \\fad."
						log.windowError message

					t1, t2, t3, t4 = tonumber( t1 ), tonumber( t2 ), tonumber( t3 ), tonumber( t4 )
					-- beautiful.
					t1 -= timeDelta
					t2 -= timeDelta
					t3 -= timeDelta
					t4 -= timeDelta
					("\\fade(%s,%s,%s,%d,%d,%d,%d)")\format a1, a2, a3, t1, t2, t3, t4

				if .move
					newText = newText\gsub moveTag.pattern, ->
						move = .move
						progress = (timeDelta - move.start)/(move.end - move.start)
						return posTag\format moveTag\interpolate {move.x1, move.y1}, {move.x2, move.y2}, progress

				-- In theory, this is more optimal if we loop over the frames on
				-- the outside loop and over the lines on the inside loop, as
				-- this only needs to be calculated once for each frame, whereas
				-- currently it is being calculated for each frame for each
				-- line. However, if the loop structure is changed, then
				-- inserting lines into the resultingCollection would need to be
				-- more clever to compensate for the fact that lines would no
				-- longer be added to it in order.
				@lineTrackingData\calculateCurrentState frame

				-- iterate through the necessary operations
				for pattern, callback in pairs @callbacks
					newText = newText\gsub pattern, ( tag, value ) ->
						tag .. callback @, value, frame

				newLine = Line line, @resultingCollection, {
					text: newText,
					start_time: newStartTime,
					end_time: newEndTime,
					transformsAreTokenized: false,
				}
				newLine.karaokeShift = (newStartTime - .start_time)*0.1

				@resultingCollection\addLine newLine, nil, true, true

	position = ( pos, frame ) =>
		x, y = pos\match "([%-%d%.]+),([%-%d%.]+)"
		x, y = positionMath x, y, @lineTrackingData
		("(%g,%g)")\format Math.round( x, 2 ), Math.round( y, 2 )

	positionMath = ( x, y, data ) ->
		x = (tonumber( x ) - data.xStartPosition)*data.xRatio
		y = (tonumber( y ) - data.yStartPosition)*data.yRatio
		radius = math.sqrt( x^2 + y^2 )
		alpha  = Math.dAtan( y, x )
		x = data.xCurrentPosition + radius*Math.dCos( alpha - data.zRotationDiff )
		y = data.yCurrentPosition + radius*Math.dSin( alpha - data.zRotationDiff )
		return x, y

	absolutePosition = ( pos, frame ) =>
		x, y = pos\match "([%-%d%.]+),([%-%d%.]+)"
		@xDelta = @lineTrackingData.xPosition[frame] - x
		@yDelta = @lineTrackingData.yPosition[frame] - y
		("(%g,%g)")\format Math.round( @lineTrackingData.xPosition[frame], 2 ), Math.round( @lineTrackingData.yPosition[frame], 2 )

	-- Needs to be fixed.
	origin = ( origin, frame ) =>
		ox, oy = origin\match("([%-%d%.]+),([%-%d%.]+)")
		ox, oy = positionMath ox, oy, @lineTrackingData
		("(%g,%g)")\format Math.round( ox, 2 ), Math.round( oy, 2 )

	scale = ( scale, frame ) =>
		scale *= @lineTrackingData.xRatio
		tostring Math.round scale, 2

	blur = ( blur, frame ) =>
		ratio = @lineTrackingData.xRatio
		ratio = 1 - (1 - ratio)*@options.main.blurScale

		tostring Math.round blur*ratio, 2

	rotate = ( rotation, frame ) =>
		rotation += @lineTrackingData.zRotationDiff
		tostring Math.round rotation, 2

	rectangularClip = ( clip, frame ) =>
		@rectClipData\calculateCurrentState frame
		@rectClipData.zRotationDiff = 0

		return clip\gsub "([%.%d%-]+),([%.%d%-]+)", ( x, y ) ->
			x, y = x + @xDelta, y + @yDelta
			x, y = positionMath x, y, @rectClipData
			("%g,%g")\format Math.round( x, 2 ), Math.round( y, 2 )

	vectorClip = ( clip, frame ) =>
		-- This is redundant if vectClipData is the same as
		-- lineTrackingData.
		@vectClipData\calculateCurrentState frame

		return clip\gsub "([%.%d%-]+) ([%.%d%-]+)", ( x, y ) ->
			x, y = x + @xDelta, y + @yDelta
			x, y = positionMath x, y, @vectClipData
			("%g %g")\format Math.round( x, 2 ), Math.round( y, 2 )

	vectorClipSRS = ( clip, frame ) =>
		return '(' .. @vectClipData.data[frame] .. ')'

if haveDepCtrl
	return version\register MotionHandler
else
	return MotionHandler
