#    DNSTraverse traverses the DNS to show statistics and information
#    Copyright (C) 2008 James Ponder
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, version 3 of the License.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

module DNSTraverse
  class ResolveError < RuntimeError
  end
  
  module MessageUtility
    module_function
    
    def msg_comment(msg, args)
      warnings = Array.new
      if args[:want_recursion] then
        if not msg.header.ra then
          warnings << "#{msg.answerfrom} doesn't allow recursion"
        end
      else
        if msg.header.ra then
          warnings << "#{msg.answerfrom} allows recursion"
        end
      end
      if msg.header.tc then
        warnings << "#{msg.answerfrom} sent truncated packet"
      end
      for warn in warnings do
        Log.warn { warn }
      end
      Log.debug { "#{msg.answerfrom} code #{msg.rcode}" }
      return warnings
    end
    
    def msg_validate(msg, args)
      a = args.dup
      a[:qclass]||= 'IN'
      return true if msg.rcode != Dnsruby::RCode.NOERROR
      begin
        if msg.question.size != 1 then
          raise ResolveError, "#{msg.answerfrom} returned unexpected " +
          "question size #{msg.question.size}"
        end
        for c in [:qname, :qclass, :qtype] do
          if a[c] and
            a[c].to_s.downcase != msg.question[0].send(c).to_s.downcase then
            raise ResolveError, "#{msg.answerfrom} returned mismatched #{c} " +
          "#{msg.question[0].send(c)} instead of expected #{a[c]}"
          end
        end
      rescue => e
        Log.debug { "Failed message was: " + msg.to_s }
        raise e
      end
      return true
    end
    
    def msg_answers?(msg, args)
      qname = args[:qname].to_s
      qclass = (args[:qclass] || 'IN').to_s
      qtype = args[:qtype].to_s
      any = qtype.casecmp('ANY') == 0 ? true : false
      ans = msg.answer.select { |x|
        x.name.to_s.casecmp(qname) == 0 && 
        x.klass.to_s.casecmp(qclass) == 0 &&
         (any || x.type.to_s.casecmp(qtype) == 0)
      }
      Log.debug { "Answers:" + ans.size.to_s}
      return ans.size > 0 ? ans : nil
    end
    
    def msg_additional?(msg, args)
      qclass = args[:qclass] || 'IN'
      Log.debug { "Looking for #{args[:qname]}/#{args[:qtype]} in additional" }
      add = msg.additional.select { |x|
        x.name.to_s.casecmp(args[:qname].to_s) == 0 && 
        x.klass.to_s.casecmp(qclass.to_s) == 0 &&
        x.type.to_s.casecmp(args[:qtype].to_s) == 0
      }
      Log.debug { add.size > 0 ? "Found #{add.size} additional records" \
        : "No additional records for #{args[:qname]}/#{args[:qtype]}"}
      return add.size > 0 ? add : nil
    end
    
    def msg_additional_ips?(msg, args)
      qclass = args[:qclass] || 'IN'
      Log.debug { "Looking for #{args[:qname]}/#{args[:qtype]} in additional" }
      if add = msg.additional.select { |x|
          x.name.to_s.casecmp(args[:qname].to_s) == 0 && 
          x.klass.to_s.casecmp(qclass.to_s) == 0 &&
          x.type.to_s.casecmp(args[:qtype].to_s) == 0
        } then
        ips = add.map {|x| x.address.to_s }
        Log.debug { "Found in additional #{args[:qname]} = " + ips.join(", ") }
        return ips
      end
      Log.debug { "No additional records for #{args[:qname]}/#{args[:qtype]}" }
      return nil
    end
    
    #    def msg_referrals(msg, args)
    #      r = msg.authority.select { |x|
    #        x.type.to_s.casecmp('NS') == 0 && x.klass.to_s.casecmp('IN') == 0
    #      }
    #      if args[:bailiwick] then
    #        b = args[:bailiwick]
    #        r = r.select { |x|
    #          zonename = x.name.to_s
    #          if cond = zonename !~ /#{@b}$/i then
    #            Log.debug { "Excluding lame referral #{b} to #{zonename}" }
    #            raise "lame"
    #          end
    #          cond
    #        }
    #      end
    #      Log.debug { "Referrals: " + r.map {|x| x.domainname.to_s }.join(", ") }
    #      return r
    #    end
    
    def msg_authority(msg)
      ns = []
      soa = []
      other = []
      for rr in msg.authority do
        type = rr.type.to_s
        klass = rr.klass.to_s
        if type.casecmp('NS') == 0 && klass.casecmp('IN') == 0
          ns << rr
        elsif type.casecmp('SOA') == 0 && klass.casecmp('IN') == 0
          soa << rr
        else
          other << rr
        end
      end
      return ns, soa, other      
    end
    
    # follow any CNAMEs in the message and return the final name
    # return nil if there is a loop
    def msg_follow_cnames(msg, args)
      name = args[:qname]
      type = args[:qtype]
      bw = args[:bailiwick].to_s
      bwend = ".#{args[:bailiwick]}"
      seen = {}
      while true do
        seen[name] = true
        return name if msg_answers?(msg, :qname => name, :qtype => type)
        if not ans = msg_answers?(msg, :qname => name, :qtype => 'CNAME') then
          return name
        end
        target = ans[0].domainname.to_s
        Log.debug { "CNAME encountered from #{name} to #{target}"}
        if name !~ /#{bwend}$/i then
          # target outside of bailiwick, don't follow any more CNAMEs.
          return target
        end
        name = target
        if seen[name] then
          Log.debug { "CNAME loop detected" }
          return nil
        end
      end
    end
    
    def msg_nodata?(msg)
      ns, soa, other = msg_authority(msg)
      if soa.size > 0 or ns.size == 0 then
        Log.debug { "NODATA: soa=#{soa.size} ns=#{ns.size}" }
        return true
      end
      return false
    end
    
    def msg_cacheable(msg, bailiwick, type = :all)
      good, bad, other = [], [], []
      bw = bailiwick.to_s
      bwend = "." + bw
      for section in [:answer, :authority, :additional] do
        for rr in msg.send(section) do
          if rr.type.to_s == "OPT" then
            other << rr
          else
            name = rr.name.to_s
            if bailiwick.nil? or name.casecmp(bw) == 0 or
              name =~ /#{bwend}$/i then
                good << rr
            else
              bad << rr
            end
          end
        end
      end
      good.map {|x| Log.debug { "Records within bailiwick: " + x.to_s } }
      bad.map {|x| Log.debug { "Records outside bailiwick: " + x.to_s } }
      other.map {|x| Log.debug { "Other records discarded: " + x.to_s } }
      return good if type == :good
      return bad if type == :bad
      return good, bad, other
    end
    
  end
end
