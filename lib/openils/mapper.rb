require 'edi/mapper'

module OpenILS
  
  class Mapper < EDI::E::Mapper
    VERSION = '0.9.9'
  end
  
end

OpenILS::Mapper.defaults = {
  'UNB' => { 'S002' => { '0007' => '31B' }, 'S003' => { '0007' => '31B' } },
  'BGM' => { 'C002' => { '1001' => 220 }, '1225' => 9 },
  'DTM' => { 'C507' => { '2005' => 137, '2379' => 102 } },
  'NAD' => { 'C082' => { '3055' => '31B' } },
  'CUX' => { 'C504' => { '6347' => 2, '6345' => 'USD', '6343' => 9 } },
  'LIN' => { 'C212' => { '7143' => 'EN' } },
  'PIA' => { '4347' => 5, 'C212' => { '7143' => 'IB' } },
  'IMD' => { '7077' => 'F' },
  'PRI' => { 'C509' => { '5125' => 'AAB' } },
  'QTY' => { 'C186' => { '6063' => 21 } },
  'UNS' => { '0081' => 'S' },
  'CNT' => { 'C270' => { '6069' => 2 } }
}

OpenILS::Mapper.map 'order' do |mapper,key,value|
  mapper.add('BGM', { '1004' => value['po_number'] })
  mapper.add('DTM', { 'C507' => { '2380' => value['date'] } })
  value['buyer'].to_a.each { |buyer| mapper.add('buyer',buyer) }
  value['vendor'].to_a.each { |vendor| mapper.add('vendor',vendor) }
  mapper.add('currency',value['currency'])

  po_name = value.has_key?('po_name') ? value['po_name'] : value['po_number']

  value['items'].each_with_index { |item,index|
    item['line_index'] = index + 1
    item['line_number'] = "#{po_name}/#{item['line_index']}" if item['line_number'].nil?
    mapper.add('item', item)
  }
  mapper.add("UNS", {})
  mapper.add("CNT", { 'C270' => { '6066' => value['line_items'] } })
  mapper.add("FTX", { 'C107' => { '4441' => value['po_note'] } }) unless value['po_note'].nil?
end

def map_identifier(data)
  id = { '7140' => data['id'] }
  if data['id-qualifier']
    id['7143'] = data['id-qualifier']
  end
  id
end

OpenILS::Mapper.map 'item' do |mapper,key,value|
  primary_id = map_identifier(value['identifiers'].first)
  mapper.add('LIN', { 'C212' => primary_id, '1082' => value['line_index'] })

  # use Array#inject() to group the identifiers in groups of 5.
  # Same as Array#in_groups_of() without the active_support dependency. 
  id_groups = value['identifiers'].inject([[]]) { |result,id|
    result.last << id
    if result.last.length == 5
      result << []
    end
    result
  }.reject { |group| group.empty? }
  
  id_groups.each { |group|
    ids = group.compact.collect { |data| 
      map_identifier(data)
    }
    mapper.add('PIA',{ 'C212' => ids })
  }
  value['desc'].each { |desc| mapper.add('desc',desc) }
  mapper.add('QTY', { 'C186' => { '6060' => value['quantity'] } })

  # map copy-level data to GIR
  if value.has_key?('copies')
    copies = value['copies']

    copies.each_with_index { |copy,index|

      break if index == 1000 # max allowed by spec

      fields = []
      fields.push({'7405' => 'LLO', '7402' => copy['owning_lib']}) if copy.has_key?('owning_lib')
      fields.push({'7405' => 'LSQ', '7402' => copy['collection_code']}) if copy.has_key?('collection_code')
      fields.push({'7405' => 'LQT', '7402' => copy['quantity']}) if copy.has_key?('quantity')
      fields.push({'7405' => 'LCO', '7402' => copy['copy_id']}) if copy.has_key?('copy_id')
      fields.push({'7405' => 'LST', '7402' => copy['item_type']}) if copy.has_key?('item_type')
      fields.push({'7405' => 'LSM', '7402' => copy['call_number']}) if copy.has_key?('call_number')
      fields.push({'7405' => 'LFN', '7402' => copy['fund']}) if copy.has_key?('fund')
      fields.push({'7405' => 'LFH', '7402' => copy['copy_location']}) if copy.has_key?('copy_location')
      fields.push({'7405' => 'LAC', '7402' => copy['barcode']}) if copy.has_key?('barcode')

      ident = sprintf('%.3d', index + 1)

      # GIR segments may only have 5 fields.  Any more and we
      # must add an additional segment with the extra fields
      mapper.add('GIR', { '7297' => ident, 'C206' => fields.slice!(0, 5) })
      if fields.length > 0
        mapper.add('GIR', { '7297' => ident, 'C206' => fields })
      end
    }
  end

  if value.has_key?('free-text')
    freetexts = value['free-text'].is_a?(Enumerable) ? value['free-text'] : [value['free-text']]
    freetexts.each { |ftx|
      chunked_text = ftx.chunk_and_group(512,5)
      chunked_text.each { |data|
        mapper.add('FTX', { '4451' => 'LIN', '4453' => 1, 'C108' => { '4440' => data } })
      }
    }
  end
  mapper.add('PRI', { 'C509' => { '5118' => value['price'] } })
  mapper.add('RFF', { 'C506' => { '1153' => 'LI', '1154' => value['line_number'] } })

end

OpenILS::Mapper.map('party',/^(buyer|vendor)$/) do |mapper,key,value|
  codes = { 'buyer' => 'BY', 'supplier' => 'SU', 'vendor' => 'SU' }
  party_code = codes[key]
  
  if value.is_a?(String)
    value = { 'id' => value }
  end

  data = { 
    '3035' => party_code, 
    'C082' => { 
      '3039' => value['id']
    }
  }
  data['C082']['3055'] = value['id-qualifier'] unless value['id-qualifier'].nil?
  mapper.add('NAD', data)

  if value['reference']
    value['reference'].each_pair { |k,v|
      mapper.add('RFF', { 'C506' => { '1153' => k, '1154' => v }})
    }
  end
end

OpenILS::Mapper.map 'currency' do |mapper,key,value|
  mapper.add('CUX', { 'C504' => ['6345' => value]})
end

OpenILS::Mapper.map 'desc' do |mapper,key,value|
  values = value.to_a.flatten
  while values.length > 0
    code = values.shift
    text = values.shift.to_s
    code_qual = code =~ /^[0-9]+$/ ? 'L' : 'F'
    chunked_text = text.chunk_and_group(35,2)
    chunked_text.each { |data|
      mapper.add('IMD', { '7077' => code_qual, '7081' => code, 'C273' => { '7008' => data } })
    }
  end
end
