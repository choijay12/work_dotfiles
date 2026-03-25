call plug#begin()
Plug 'morhetz/gruvbox'
call plug#end()

colorscheme gruvbox
set background=dark

" Visual
set number
set cursorline          " highlight current line
set scrolloff=8         " keep 8 lines above/below cursor

" Indentation
set tabstop=4
set shiftwidth=4
set expandtab           " use spaces instead of tabs
set smartindent

" Search
set ignorecase          " case insensitive search
set smartcase           " unless you type uppercase
set hlsearch            " highlight search results
set incsearch           " highlight as you type

" Usability
set nowrap              " don't wrap long lines
set clipboard=unnamed   " use system clipboard
set mouse=a             " enable mouse
set undofile            " persistent undo after closing file

" Performance
set updatetime=50
set timeoutlen=300

