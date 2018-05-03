# encoding: utf-8

# Returns a new String with any number of instances of the given characters in
# any order removed from both the beginning and the end.
#
#     "foobar".stripchomp('of')  #=> "bar"
#     "foobar".stripchomp('rf')  #=> "ooba"
#     "foobar".stripchomp('for') #=> "ba"
#     "foobar".stripchomp('f')   #=> "oobar"
class String
  def stripchomp(chars)
    str = clone
    str.gsub(/^[#{chars}]+|[#{chars}]+$/, '')
  end
end

# Paper over fragile, inflexible URI::join
# 1) URI::join doesn't handle extraneous leading and trailing slashes
# 2) URI::join requires host with scheme
def uri_join(host, *parts)
  newparts = []
  newparts << (parts[0] =~ /^http/ ? parts.shift : host)
  newparts.push(*parts)
  newparts = newparts.reject(&:nil?).map {|part| part.to_s.stripchomp('/')}
  newparts.join('/')
end

def numeric?(value)
  !!(value.to_s =~ /^[0-9]+$/)
end
