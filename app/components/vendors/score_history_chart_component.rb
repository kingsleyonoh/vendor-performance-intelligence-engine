# frozen_string_literal: true

# Vendors::ScoreHistoryChartComponent — inline SVG sparkline for the last
# ~90 days of composite_score values. Keeping this pure-SVG avoids pulling
# a JS charting lib in Phase 1; the chart is driven entirely by server-
# rendered data points.
#
# `history` is an array of [computed_at, composite_score, band] tuples
# sorted ASCending by computed_at. Values are in [0, 100].
module Vendors
  class ScoreHistoryChartComponent < ViewComponent::Base
    WIDTH = 600
    HEIGHT = 140
    PADDING = 10

    def initialize(history:)
      @history = Array(history)
    end

    attr_reader :history

    def empty?
      history.length < 2
    end

    # Produce the SVG polyline "points" string, mapping each (computed_at,
    # score) to (x, y) inside the SVG viewBox. X = linear over index,
    # Y = inverted (0 at top, 100 at bottom of plot area).
    def polyline_points
      return "" if empty?

      plot_width = WIDTH - 2 * PADDING
      plot_height = HEIGHT - 2 * PADDING
      steps = history.length - 1

      history.each_with_index.map do |(_, score, _), idx|
        x = PADDING + (plot_width * idx.to_f / steps)
        y_ratio = [[score.to_f, 0.0].max, 100.0].min / 100.0
        y = PADDING + plot_height - (plot_height * y_ratio)
        "#{x.round(1)},#{y.round(1)}"
      end.join(" ")
    end

    # Last point for the "current score" dot.
    def last_point
      return nil if empty?
      parts = polyline_points.split(" ")
      parts.last
    end

    def viewbox
      "0 0 #{WIDTH} #{HEIGHT}"
    end
  end
end
