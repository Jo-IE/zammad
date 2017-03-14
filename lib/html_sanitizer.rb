class HtmlSanitizer

=begin

satinize html string based on whiltelist

  string = HtmlSanitizer.strict(string, external)

=end

  def self.strict(string, external = false)

    # config
    tags_remove_content = Rails.configuration.html_sanitizer_tags_remove_content
    tags_quote_content = Rails.configuration.html_sanitizer_tags_quote_content
    tags_whitelist = Rails.configuration.html_sanitizer_tags_whitelist
    attributes_whitelist = Rails.configuration.html_sanitizer_attributes_whitelist
    css_properties_whitelist = Rails.configuration.html_sanitizer_css_properties_whitelist
    classes_whitelist = ['js-signatureMarker']
    attributes_2_css = %w(width height)

    scrubber = Loofah::Scrubber.new do |node|

      # remove tags with subtree
      if tags_remove_content.include?(node.name)
        node.remove
        Loofah::Scrubber::STOP
      end

      # remove tag, insert quoted content
      if tags_quote_content.include?(node.name)
        string = node.content
        string.gsub!('&amp;', '&')
        string.gsub!('&lt;', '<')
        string.gsub!('&gt;', '>')
        string.gsub!('&quot;', '"')
        string.gsub!('&nbsp;', ' ')
        text = Nokogiri::XML::Text.new(string, node.document)
        node.add_next_sibling(text)
        node.remove
        Loofah::Scrubber::STOP
      end

      # replace tags, keep subtree
      if !tags_whitelist.include?(node.name)
        node.replace strict(node.children.to_s)
        Loofah::Scrubber::STOP
      end

      # prepare src attribute
      if node['src']
        src = cleanup_target(node['src'])
        if src =~ /(javascript|livescript|vbscript):/i || src.start_with?('http', 'ftp', '//')
          node.remove
          Loofah::Scrubber::STOP
        end
      end

      # clean class / only use allowed classes
      if node['class']
        classes = node['class'].gsub(/\t|\n|\r/, '').split(' ')
        class_new = ''
        classes.each { |local_class|
          next if !classes_whitelist.include?(local_class.to_s.strip)
          if class_new != ''
            class_new += ' '
          end
          class_new += local_class
        }
        if class_new != ''
          node['class'] = class_new
        else
          node.delete('class')
        end
      end

      # move style attributes to css attributes
      attributes_2_css.each { |key|
        next if !node[key]
        if node['style'].empty?
          node['style'] = ''
        else
          node['style'] += ';'
        end
        value = node[key]
        node.delete(key)
        next if value.blank?
        if value !~ /%|px|em/i
          value += 'px'
        end
        node['style'] += "#{key}:#{value}"
      }

      # clean style / only use allowed style properties
      if node['style']
        pears = node['style'].downcase.gsub(/\t|\n|\r/, '').split(';')
        style = ''
        pears.each { |local_pear|
          prop = local_pear.split(':')
          next if !prop[0]
          key = prop[0].strip
          next if !css_properties_whitelist.include?(key)
          style += "#{local_pear};"
        }
        node['style'] = style
        if style == ''
          node.delete('style')
        end
      end

      # scan for invalid link content
      %w(href style).each { |attribute_name|
        next if !node[attribute_name]
        href = cleanup_target(node[attribute_name])
        next if href !~ /(javascript|livescript|vbscript):/i
        node.delete(attribute_name)
      }

      # remove attributes if not whitelisted
      node.each { |attribute, _value|
        attribute_name = attribute.downcase
        next if attributes_whitelist[:all].include?(attribute_name) || (attributes_whitelist[node.name] && attributes_whitelist[node.name].include?(attribute_name))
        node.delete(attribute)
      }

      # remove mailto links
      if node['href']
        href = cleanup_target(node['href'])
        if href =~ /mailto:(.*)$/i
          text = Nokogiri::XML::Text.new($1, node.document)
          node.add_next_sibling(text)
          node.remove
          Loofah::Scrubber::STOP
        end
      end

      # prepare links
      if node['href']
        href = cleanup_target(node['href'])
        next if !href.start_with?('http', 'ftp', '//')
        node.set_attribute('href', href)
        node.set_attribute('rel', 'nofollow')
        node.set_attribute('target', '_blank')
      end

      # check if href is different to text
      if external && node.name == 'a' && !url_same?(node['href'], node.text)
        if node['href'].blank?
          node.replace strict(node.children.to_s)
          Loofah::Scrubber::STOP
        elsif node.children.empty? || node.children.first.class == Nokogiri::XML::Text
          text = Nokogiri::XML::Text.new("#{node['href']} (", node.document)
          node.add_previous_sibling(text)
          node['href'] = cleanup_target(node.text)
          text = Nokogiri::XML::Text.new(')', node.document)
          node.add_next_sibling(text)
        else
          text = Nokogiri::XML::Text.new(cleanup_target(node['href']), node.document)
          node.content = text
        end
      end

      # check if text has urls which need to be clickable
      if node && node.name != 'a' && node.parent && node.parent.name != 'a' && (!node.parent.parent || node.parent.parent.name != 'a')
        if node.class == Nokogiri::XML::Text
          urls = []
          node.content.scan(%r{((http|https|ftp|tel)://.+?|(www..+?))([[:space:]]|\.[[:space:]]|,[[:space:]]|\.$|,$|\)|\(|$)}mxi).each { |match|
            urls.push match[0]
          }
          next if urls.empty?
          add_link(node.content, urls, node)
        end
      end

    end
    Loofah.fragment(string).scrub!(scrubber).to_s
  end

=begin

cleanup html string:

 * remove empty nodes (p, div, span)
 * remove nodes in general (keep content - span)

  string = HtmlSanitizer.cleanup(string)

=end

  def self.cleanup(string)
    string.gsub!(/<[A-z]:[A-z]>/, '')
    string.gsub!(%r{</[A-z]:[A-z]>}, '')
    string.delete!("\t")

    # remove all new lines
    string.gsub!(/(\n\r|\r\r\n|\r\n|\n)/, "\n")

    # remove double multiple empty lines
    string.gsub!(/\n\n\n+/, "\n\n")

    string = cleanup_replace_tags(string)
    cleanup_structure(string)
  end

  def self.cleanup_replace_tags(string)
    string.gsub!(%r{(<table(.+?|)>.+?</table>)}mxi) { |table|
      table.gsub!(/<table(.+?|)>/im, '<br>')
      table.gsub!(%r{</table>}im, ' ')
      table.gsub!(/<thead(.+?|)>/im, '')
      table.gsub!(%r{</thead>}im, ' ')
      table.gsub!(/<tbody(.+?|)>/im, '')
      table.gsub!(%r{</tbody>}im, ' ')
      table.gsub!(/<tr(.+?|)>/im, "<br>\n")
      #table.gsub!(%r{</td>}im, '')
      #table.gsub!(%r{</td>}im, "\n<br>\n")
      table.gsub!(%r{</td>}im, ' ')
      table.gsub!(/<td(.+?|)>/im, '')
      #table.gsub!(%r{</tr>}im, '')
      table.gsub!(%r{</tr>}im, "\n<br>")
      table.gsub!(/<br>[[:space:]]?<br>/im, '<br>')
      table.gsub!(/<br>[[:space:]]?<br>/im, '<br>')
      table.gsub!(%r{<br/>[[:space:]]?<br/>}im, '<br/>')
      table.gsub!(%r{<br/>[[:space:]]?<br/>}im, '<br/>')
      table
    }

    tags_backlist = %w(span table thead tbody td tr center)
    scrubber = Loofah::Scrubber.new do |node|
      next if !tags_backlist.include?(node.name)
      node.replace cleanup_replace_tags(node.children.to_s)
      Loofah::Scrubber::STOP
    end
    Loofah.fragment(string).scrub!(scrubber).to_s
  end

  def self.cleanup_structure(string)
    remove_empty_nodes = %w(p div span small)
    remove_empty_last_nodes = %w(b i u small)

    scrubber = Loofah::Scrubber.new do |node|
      if remove_empty_last_nodes.include?(node.name) && node.children.size.zero?
        node.remove
        Loofah::Scrubber::STOP
      end

      if remove_empty_nodes.include?(node.name) && node.children.size == 1 && remove_empty_nodes.include?(node.children.first.name) # && node.children.first.text.blank?
        node.replace cleanup_structure(node.children.to_s)
      end

      # remove mailto links
      if node['href']
        href = cleanup_target(node['href'])
        if href =~ /mailto:(.*)$/i
          text = Nokogiri::XML::Text.new($1, node.document)
          node.add_next_sibling(text)
          node.remove
          Loofah::Scrubber::STOP
        end
      end

      # check if href is different to text
      if node.name == 'a' && !url_same?(node['href'], node.text)
        if node['href'].blank?
          node.replace cleanup_structure(node.children.to_s)
          Loofah::Scrubber::STOP
        elsif node.children.empty? || node.children.first.class == Nokogiri::XML::Text
          text = Nokogiri::XML::Text.new("#{node.text} (", node.document)
          node.add_previous_sibling(text)
          node.content = cleanup_target(node['href'])
          node['href'] = cleanup_target(node['href'])
          text = Nokogiri::XML::Text.new(')', node.document)
          node.add_next_sibling(text)
        else
          text = Nokogiri::XML::Text.new(cleanup_target(node['href']), node.document)
          node.content = text
        end
      end

      # remove not needed new lines
      if node.class == Nokogiri::XML::Text
        if !node.parent || (node.parent.name != 'pre' && node.parent.name != 'code')
          content = node.content
          if content
            if content != ' ' && content != "\n"
              content.gsub!(/[[:space:]]+/, ' ')
            end
            if node.previous
              if node.previous.name == 'div' || node.previous.name == 'p'
                content.strip!
              end
            elsif node.parent && !node.previous
              if (node.parent.name == 'div' || node.parent.name == 'p') && content != ' ' && content != "\n"
                content.strip!
              end
            end
            node.content = content
          end
        end
      end
    end
    Loofah.fragment(string).scrub!(scrubber).to_s
  end

  def self.add_link(content, urls, node)
    if urls.empty?
      text = Nokogiri::XML::Text.new(content, node.document)
      node.add_next_sibling(text)
      return
    end
    url = urls.shift

    if content =~ /^(.*)#{Regexp.quote(url)}(.*)$/mx
      pre = $1
      post = $2

      if url =~ /^www/i
        url = "http://#{url}"
      end

      a = Nokogiri::XML::Node.new 'a', node.document
      a['href'] = url
      a['rel'] = 'nofollow'
      a['target'] = '_blank'
      a.content = url

      if node.class != Nokogiri::XML::Text
        text = Nokogiri::XML::Text.new(pre, node.document)
        node.add_next_sibling(text).add_next_sibling(a)
        return if post.blank?
        add_link(post, urls, a)
        return
      end
      node.content = pre
      node.add_next_sibling(a)
      return if post.blank?
      add_link(post, urls, a)
    end
  end

  def self.cleanup_target(string)
    URI.unescape(string).downcase.gsub(/[[:space:]]|\t|\n|\r/, '').gsub(%r{/\*.*?\*/}, '').gsub(/<!--.*?-->/, '').gsub(/\[.+?\]/, '')
  end

  def self.url_same?(url_new, url_old)
    url_new = URI.unescape(url_new.to_s).downcase.gsub(%r{/$}, '').gsub(/[[:space:]]|\t|\n|\r/, '').strip
    url_old = URI.unescape(url_old.to_s).downcase.gsub(%r{/$}, '').gsub(/[[:space:]]|\t|\n|\r/, '').strip
    return true if url_new == url_old
    return true if "http://#{url_new}" == url_old
    return true if "http://#{url_old}" == url_new
    return true if "https://#{url_new}" == url_old
    return true if "https://#{url_old}" == url_new
    false
  end

  private_class_method :cleanup_target
  private_class_method :add_link
  private_class_method :url_same?

end