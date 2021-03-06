require 'nokogiri'
require 'open-uri'


class Property < ApplicationRecord
  include Sidekiq::Worker

  def self.zoolpla_crawl(location, radius)
    new_radius = radius.to_i
    base_url = 'https://www.zoopla.co.uk/'
    name = location.displayname.gsub(',','').split(' ').first(2).join('-')
    location_spaces_removed = location.displayname.gsub(' ','%20')
    pn = 1
    pagination_count = 2
    loop do
      url = base_url + "for-sale/property/#{name}/?q=#{location_spaces_removed}&results_sort=newest_listings&search_source=home&page_size=100&pn=#{pn}&radius=#{new_radius}"
      puts url
      doc = Nokogiri::HTML(open(url.strip))
      return [] if doc.css('div.listing-results-utils-view.clearfix.bg-muted').text.strip.include?('No results found')

      pagination_count = doc.css('div.paginate.bg-muted a').map{|a| a.text.to_i}.max

      begin
        properties_data = []
        doc.css('li.srp.clearfix').each do |property|
          source_url = property.css('div.listing-results-right.clearfix a').first['href']
          next unless source_url.present?

          source_url = 'https://www.zoopla.co.uk' + source_url
          properties_data << {
              images: property.css('.photo-hover img').map{|s| s['src'] if s['src'].present?}.compact,
              name: property.css('h2.listing-results-attr a').first.text,
              description: (property.css('div.listing-results-right.clearfix p').first.text.strip rescue ''),
              price: (property.css('div.listing-results-right.clearfix a').first.text.strip.split(' ').first.gsub(',','')[1..-1].to_f rescue 0.0),
              source: 'Zoopla',
              source_url: source_url,
              created_at: Time.now,
              updated_at: Time.now

          }
        end
        Property.insert_data_into_db(properties_data, location, radius)
      rescue => e
        puts "=======#{e.to_s}===="
      end
      return [] if pn == pagination_count
      pn += 1
    end
    []
  end

  def perform(pd_id)
    pq = PropertyQueue.find(pd_id)
    return unless pq.status == 'pending'
    pq.update(status: 'in_process')
    location = Location.find(pq.location_id)
    unless location.locationidentifier.nil?
      # We can scrap the rightmove.co.uk for this keyword
      properties_data = []
      need_to_break = false
      for i in 0 .. 45
        index = i * 24
        begin
          url = "https://www.rightmove.co.uk/property-for-sale/find.html?searchType=SALE&locationIdentifier=#{location.locationidentifier}&index=#{index}&insId=1&radius=0.0"
          doc = Nokogiri::HTML(open(url.strip))
          old_properties_data_count = properties_data.count
          doc.css('div.l-searchResult.is-list.is-not-grid').each do |property|
            property_images = property.css('img').map{|p| p['src'] if p['src'].present?}.compact
            property_price = property.css('div.propertyCard-priceValue').first.text.strip.gsub(',','')[1..-1].to_f rescue 0.0
            source_url = (property.css('.propertyCard-link').first['href']) rescue nil
            next unless source_url.present?
            source_url = 'https://www.rightmove.co.uk' + source_url
            properties_data << {
                images: property_images,
                name: property.css('h2').first.text.strip,
                description: property.css('.propertyCard-link').text.strip.tr("\n",""),
                price: property_price,
                source: 'Rightmove',
                source_url: source_url,
                created_at: Time.now,
                updated_at: Time.now

            }
          end
        rescue
          need_to_break = true
        end
        need_to_break = true  if properties_data.count == old_properties_data_count
        break if need_to_break
      end
      Property.insert_data_into_db(properties_data, location, pq.radius)
      Property.zoolpla_crawl(location, pq.radius)
      pq.update(status: 'finished')
    end
  end

  def self.insert_data_into_db(properties_data, location, radius)
    Property.insert_all(properties_data)
    property_ids = Property.where(:source_url => properties_data.map{|s| s[:source_url]}).pluck(:id)
    locations_properties_data = []
    property_ids.each do |prop_id|
      locations_properties_data << {
          location_id: location.id,
          property_id: prop_id,
          radius: radius,
          is_active: true,
          created_at: Time.now,
          updated_at: Time.now
      }
    end
    LocationsProperty.insert_all(locations_properties_data)
  end
end
