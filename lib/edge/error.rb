# frozen_string_literal: true

module Edge
  # Base class for every error this library raises, so callers can rescue the
  # whole library with one constant.
  class Error < StandardError; end
end
