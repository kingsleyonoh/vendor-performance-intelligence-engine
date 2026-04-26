# frozen_string_literal: true

# VendorAliasesHelper — confidence-pill color helpers for the pending
# alias queue (`/aliases/pending`). Mirrors the band/status helper pattern
# used elsewhere (Reports, Alerts).
module VendorAliasesHelper
  def confidence_bg(value)
    case value.to_f
    when 0.95..1.0 then "#C6F6D5"  # green-ish
    when 0.80...0.95 then "#FEFCBF"  # yellow
    else                "#FED7D7"  # red
    end
  end

  def confidence_fg(value)
    case value.to_f
    when 0.95..1.0 then "#22543D"
    when 0.80...0.95 then "#744210"
    else                "#742A2A"
    end
  end
end
