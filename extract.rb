require 'nokogiri'
require 'json'

filename = ARGV[0]

doc = Nokogiri::XML(`gzip -cd '#{filename}'`)

clips = doc.css('AudioClip')
bpm = doc.at_css('Tempo>Manual')['Value'].to_f

tracks = ARGV.drop(1).zip(%w(A B)).to_h

clips = clips.to_a.map do |clip|
  track = tracks[clip.ancestors('AudioTrack').at_css('EffectiveName')['Value']]

  # We skip the current track if it's not specified
  next unless track

  beat = clip.at_css('CurrentStart')['Value'].to_f
  warped = clip.at_css('IsWarped')['Value'] == 'true'
  name = clip.at_css('FileRef Name')['Value']

  t0 = clip.at_css('WarpMarkers>WarpMarker[BeatTime="0"]')['SecTime'].to_f
  t1 = clip.at_css('WarpMarkers>WarpMarker[BeatTime="0.03125"]')['SecTime'].to_f

  t_start = clip.at_css('Loop>LoopStart')['Value'].to_f

  # We calculate the timestep.
  # The warpmarkers t0 and t1 are selected to be 1/32th beats apart
  # spb == seconds per beat
  spb = 32 * (t1 - t0)
  t_bpm = 60 / spb

  # The first warp marker is coincidentally the offset
  offset = t0
  offset += (t_start * spb) if warped
  stretch = bpm / t_bpm

  rel_path = clip.at_css('FileRef').css('RelativePath>RelativePathElement')
                 .map { |e| e['Dir'].empty? ? '..' : e['Dir'] }

  {
    name: name,
    relative_path: (rel_path + [name]).join('/'),
    time: ((beat / bpm) * 60),
    offset: offset / stretch,
    track: track,
    stretch: stretch,
    end: 60 * clip.at_css('CurrentEnd')['Value'].to_f / bpm
  }
end

# Filter out null values
clips.select! { |e| e }

# Extract crossfade events
cf_events = doc.at_css('CrossFade>ArrangerAutomation>Events').css('FloatEvent')

cf_events = cf_events.to_a.map do |fe|
  {
    time: 60 * fe['Time'].to_f / bpm,
    value: (1 + fe['Value'].to_f) / 2.0
  }
end

# Extract all the crossfades
xfades = cf_events.drop(1).each_with_object([[]]) do |event, memo|
  # If event is integer
  memo[-1] << event if event[:value] == event[:value].to_i
  memo << [] if event[:value] == 1 - (memo.size % 2)
end.reject(&:empty?)

final_json = {
  bpm: bpm,
  clips: clips,
  crossfade: {
    curve: doc.at_css('CrossfadeCurve')['Value'],
    events: cf_events
  },
  xfade_positions: xfades.map { |e| { start: e[0][:time], end: e[1][:time] } }
}.to_json

puts final_json
