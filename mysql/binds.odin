package mysql

import "core:c"
import "core:time"

@(private)
Bind_Nil :: Bind {
	buffer_type = .Null,
}

@(private)
not_nil := false
@(private)
is_nil := true

bindp_nil :: proc() -> Bind {
	return Bind_Nil
}

bindp_text :: proc(str: string, allocator := context.allocator) -> (bind: Bind, allocated_len: ^c.ulong) {
	str_len := new(c.ulong, allocator)
	str_len^ = c.ulong(len(str))

	return Bind{
			buffer_type = .String,
			buffer = raw_data(str),
			buffer_length = str_len^,
			length = str_len,
			is_null = &not_nil,
		},
		str_len
}
bindp_char :: bindp_text
bindp_var_char :: bindp_text

bindr_text :: proc(buf: []byte, length_ptr: ^c.ulong) -> Bind {
    return Bind{
        buffer_type = .String,
        buffer = raw_data(buf),
        buffer_length = c.ulong(len(buf)),
        length = length_ptr,
    }
}
bindr_char :: bindr_text
bindr_var_char :: bindr_text

bindp_blob :: proc(str: string, allocator := context.allocator) -> (bind: Bind, allocated_len: ^c.ulong) {
	str_len := new(c.ulong, allocator)
	str_len^ = c.ulong(len(str))

	return Bind{
			buffer_type = .Blob,
			buffer = raw_data(str),
			buffer_length = str_len^,
			length = str_len,
			is_null = &not_nil,
		},
		str_len
}
bindp_binary :: bindp_blob
bindp_var_binary :: bindp_blob

bindp_tiny_int :: proc(ch: ^c.char) -> Bind {
	return Bind{buffer_type = .Tiny, buffer = ch, is_null = ch == nil ? &is_nil : &not_nil}
}

bindp_small_int :: proc(i: ^c.short) -> Bind {
	return Bind{buffer_type = .Short, buffer = i, is_null = i == nil ? &is_nil : &not_nil}
}

bindp_int :: proc(i: ^c.int) -> Bind {
    return Bind{buffer_type = .Long, buffer = i, is_null = i == nil ? &is_nil : &not_nil}
}

bindp_big_int :: proc(i: ^c.longlong) -> Bind {
	return Bind{buffer_type = .Long_Long, buffer = i, is_null = i == nil ? &is_nil : &not_nil}
}

bindp_float :: proc(i: ^c.float) -> Bind {
	return Bind{buffer_type = .Float, buffer = i, is_null = i == nil ? &is_nil : &not_nil}
}

bindp_double :: proc(i: ^c.double) -> Bind {
	return Bind{buffer_type = .Double, buffer = i, is_null = i == nil ? &is_nil : &not_nil}
}

bindp_time_mysql :: proc(t: ^Time, type: Time_Type) -> Bind {
	bt: Buffer_Type
	switch type {
	case .Time:
		bt = .Time
	case .Date_Time:
		bt = .Date_Time
	case .Timestamp:
		bt = .Timestamp
	case .Date:
		bt = .Date
	}

	return Bind{buffer_type = bt, buffer = t}
}

bindp_time_time :: proc(
	t: time.Time,
	type: Time_Type,
	allocator := context.allocator,
) -> (
	Bind,
	^Time,
) {
	mt := new(Time, allocator)
	time_from_time(mt, t, type)
	return bindp_time_mysql(mt, type), mt
}

bindp_time :: proc {
	bindp_time_mysql,
	bindp_time_time,
}
