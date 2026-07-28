module VgCli
  module Table
    def self.print(headers, rows)
      if rows.empty?
        puts "(no rows)"
        return
      end

      columns = headers.each_with_index.map do |header, index|
        [header.to_s, *rows.map { |row| row[index].to_s }].map(&:length).max
      end

      print_row(headers, columns)
      puts columns.map { |width| "-" * width }.join("  ")
      rows.each { |row| print_row(row, columns) }
    end

    def self.print_row(row, columns)
      puts row.each_with_index.map { |cell, index| cell.to_s.ljust(columns[index]) }.join("  ")
    end
    private_class_method :print_row
  end
end
