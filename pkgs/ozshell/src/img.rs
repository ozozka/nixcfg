//! Image decoding for the wallpaper, application icons and notification images.

use egui::ColorImage;

/// Loads a PNG, JPEG or SVG file; SVGs are rendered at `px` pixels.
pub fn load(path: &str, px: Option<u32>) -> Option<ColorImage> {
    let path = path.strip_prefix("file://").unwrap_or(path);
    let data = std::fs::read(path).ok()?;
    if data.starts_with(b"\x89PNG") {
        png(&data)
    } else if data.starts_with(&[0xff, 0xd8]) {
        jpeg(&data)
    } else {
        svg(&data, px.unwrap_or(256))
    }
}

fn png(data: &[u8]) -> Option<ColorImage> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(data));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let px = &buf[..info.buffer_size()];
    let rgba: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => px.to_vec(),
        png::ColorType::Rgb => {
            px.as_chunks::<3>().0.iter().flat_map(|c| [c[0], c[1], c[2], 255]).collect()
        }
        png::ColorType::GrayscaleAlpha => {
            px.as_chunks::<2>().0.iter().flat_map(|c| [c[0], c[0], c[0], c[1]]).collect()
        }
        _ => px.iter().flat_map(|&g| [g, g, g, 255]).collect(),
    };
    Some(ColorImage::from_rgba_unmultiplied([info.width as usize, info.height as usize], &rgba))
}

fn jpeg(data: &[u8]) -> Option<ColorImage> {
    use zune_jpeg::zune_core::{
        bytestream::ZCursor, colorspace::ColorSpace, options::DecoderOptions,
    };
    let opts = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut dec = zune_jpeg::JpegDecoder::new_with_options(ZCursor::new(data), opts);
    let px = dec.decode().ok()?;
    let (w, h) = dec.dimensions()?;
    Some(ColorImage::from_rgba_unmultiplied([w, h], &px))
}

fn svg(data: &[u8], px: u32) -> Option<ColorImage> {
    let tree = resvg::usvg::Tree::from_data(data, &Default::default()).ok()?;
    let size = tree.size();
    let scale = px as f32 / size.width().max(size.height());
    let mut map = resvg::tiny_skia::Pixmap::new(px, px)?;
    let dx = (px as f32 - size.width() * scale) / 2.0;
    let dy = (px as f32 - size.height() * scale) / 2.0;
    let transform = resvg::tiny_skia::Transform::from_row(scale, 0.0, 0.0, scale, dx, dy);
    resvg::render(&tree, transform, &mut map.as_mut());
    Some(ColorImage::from_rgba_premultiplied([px as usize, px as usize], map.data()))
}

/// Raw notification `image-data`: width, height, rowstride, alpha, bits, channels, bytes.
pub fn raw(
    w: i32,
    h: i32,
    stride: i32,
    alpha: bool,
    channels: i32,
    data: &[u8],
) -> Option<ColorImage> {
    let (w, h, stride, ch) = (w as usize, h as usize, stride as usize, channels as usize);
    let mut rgba = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        for x in 0..w {
            let p = data.get(y * stride + x * ch..y * stride + x * ch + ch)?;
            rgba.extend([p[0], p[1], p[2], if alpha && ch > 3 { p[3] } else { 255 }]);
        }
    }
    Some(ColorImage::from_rgba_unmultiplied([w, h], &rgba))
}
