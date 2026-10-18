if (cur_ind >= global.dialog_files_number)
{
	exit;
}
var fname = ds_list_find_value(global.dialog_files, cur_ind);
var t = "";
var f = file_text_open_read("host:/" + fname);
if (f >= 0)
{
	while (!file_text_eof(f))
	{
		t += file_text_readln(f);
		t += "\r\n";
	}
	file_text_close(f);
}
ds_map_set(global.dialog_files_texts, fname, t);
show_debug_message("LOADED " + fname + " len=" + string(string_length(t)));
cur_ind += 1;
