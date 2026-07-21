# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module EdgeSuite
  # Durable gateway statistics. Two artifacts live under one directory:
  #
  #   snapshot.json   - the latest per-channel report array (atomic overwrite)
  #   anomalies.jsonl - append-only log, one JSON object per anomaly event
  #
  # JSON + JSONL keeps the store dependency-free and trivially inspectable
  # (`tail -f anomalies.jsonl`), while the append-only log means a crash loses
  # at most the in-flight line, never the history. Snapshots are written via a
  # temp file + rename so a reader never sees a half-written file.
  class StatsStore
    SNAPSHOT = "snapshot.json"
    ANOMALIES = "anomalies.jsonl"

    attr_reader :dir

    def initialize(dir:)
      @dir = dir
      FileUtils.mkdir_p(@dir)
      @snapshot_path = File.join(@dir, SNAPSHOT)
      @anomalies_path = File.join(@dir, ANOMALIES)
      @anomaly_log = File.open(@anomalies_path, "a")
      @anomaly_log.sync = true
    end

    # Append one anomaly event. `ts` defaults to now (UTC ISO-8601); pass an
    # explicit value for deterministic output.
    def record_anomaly(channel:, index:, value:, score:, ts: nil)
      @anomaly_log.puts(JSON.generate(
        ts: ts || Time.now.utc.iso8601,
        channel: channel,
        index: index,
        value: value,
        score: score.round(4)
      ))
    end

    # Atomically overwrite the snapshot with the given report array.
    def write_snapshot(reports, ts: nil)
      payload = { updated_at: ts || Time.now.utc.iso8601, channels: reports }
      tmp = "#{@snapshot_path}.tmp"
      File.write(tmp, JSON.pretty_generate(payload))
      File.rename(tmp, @snapshot_path) # atomic on POSIX
      payload
    end

    # Load the last snapshot, or nil if none has been written yet.
    def load_snapshot
      return nil unless File.exist?(@snapshot_path)

      JSON.parse(File.read(@snapshot_path), symbolize_names: true)
    end

    # Number of anomaly events currently on disk (counts log lines).
    def anomaly_count
      return 0 unless File.exist?(@anomalies_path)

      File.foreach(@anomalies_path).count
    end

    # Iterate persisted anomaly events (parsed Hashes).
    def each_anomaly
      return enum_for(:each_anomaly) unless block_given?
      return unless File.exist?(@anomalies_path)

      File.foreach(@anomalies_path) do |line|
        line = line.strip
        next if line.empty?

        yield JSON.parse(line, symbolize_names: true)
      end
    end

    def close
      @anomaly_log.close unless @anomaly_log.closed?
    end
  end
end
