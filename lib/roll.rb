require 'securerandom'

class Integer
  def d(n)
    #(1..self).inject(0) {|a,e| a + rand(n) + 1}
    (1..self).inject(0) {|a,e| a + SecureRandom.random_number(n) + 1}
  end
end

class Dice
  def initialize(dice)
    @src = dice.gsub(/d(%|00)(\D|$)/, 'd100\2').
                gsub(/d(\d+)/, 'd(\1)').
                gsub(/(\d+|\))d/, '\1.d').
                gsub(/\d+/) { $&.gsub(/^0+/, '') }
    raise ArgumentError, "invalid dice: '#{dice}'" if @src =~ /[^-+\/*()d0-9. ]/
    
    begin
      @dice = eval "lambda{ #@src }"
      roll
    rescue
      raise ArgumentError, "invalid dice: '#{dice}'"
    end
  end

  def d(n)
    1.d(n)
  end

  def roll
    @dice.call
  end
end
