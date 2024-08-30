class JsonParser
  attr_reader :json, :test_count, :tests, :commentary, :passed_count, :time_taken
  attr_reader :filename
  attr_reader :score, :max_score

  def initialize(json, filename=nil)
    @filename = filename
    @json = json
    @tests = json['tests']
    @test_count = @tests.count
    @tests.each do |t|
      t[:passed] = (t['score'] == t['max_score'])
    end
    @passed_count = @tests.count { |t| t[:passed] }
    @score = @json['score']
    @max_score = @json['max-score']
  end
end
